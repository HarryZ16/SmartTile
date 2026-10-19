import XCTest
import CoreGraphics
@testable import SmartTile

/// The layout engine is a pure function: windows + screens in, a position per window out.
/// These tests cover common setups and edge cases.
final class LayoutEngineTests: XCTestCase {
    // MacBook built-in screen (AX coordinates, 33pt menu bar at the top)
    let laptop = ScreenInfo(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                            visible: CGRect(x: 0, y: 33, width: 1512, height: 949))

    func external(x: CGFloat, width: CGFloat = 2560, height: CGFloat = 1440) -> ScreenInfo {
        ScreenInfo(frame: CGRect(x: x, y: -300, width: width, height: height),
                   visible: CGRect(x: x, y: -275, width: width, height: height - 25))
    }

    func item(_ id: CGWindowID, _ role: Role, bundle: String? = nil, key: String? = nil) -> LayoutItem {
        let b = bundle ?? "app.\(id)"
        return LayoutItem(id: id, bundleID: b, key: key ?? b, role: role)
    }

    // MARK: Assertion helpers

    func assertInside(_ frames: [CGRect], _ area: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        for f in frames {
            XCTAssertTrue(area.insetBy(dx: -1, dy: -1).contains(f), "\(f) is outside \(area)", file: file, line: line)
        }
    }

    /// Visible windows either coincide exactly (stacked) or don't overlap at all.
    func assertNoPartialOverlap(_ frames: [CGRect], file: StaticString = #filePath, line: UInt = #line) {
        for i in frames.indices {
            for j in frames.indices where j > i {
                let a = frames[i], b = frames[j]
                if a.isClose(to: b, tol: 0.5) { continue }
                let inter = a.intersection(b)
                let area = inter.isNull ? 0 : inter.width * inter.height
                XCTAssertLessThan(area, 1, "\(a) and \(b) partially overlap", file: file, line: line)
            }
        }
    }

    // MARK: Single screen

    func testSingleScreenMainReferenceAux() {
        let r = LayoutEngine.plan([item(1, .main), item(2, .reference), item(3, .aux)],
                                  screens: [laptop], params: LayoutParams())
        let main = r.slots[1]!.frame, ref = r.slots[2]!.frame, aux = r.slots[3]!.frame
        XCTAssertLessThan(main.maxX, ref.minX, "code on the left, reference on the right")
        XCTAssertLessThan(ref.maxY, aux.minY, "reference above aux")
        XCTAssertEqual(ref.minX, aux.minX)
        let inner = laptop.visible.insetBy(dx: 8, dy: 8)
        XCTAssertEqual(Double(main.width / (inner.width - 8)), 0.6, accuracy: 0.01, "code area is 60% by default")
        assertInside([main, ref, aux], laptop.visible)
        assertNoPartialOverlap([main, ref, aux])
    }

    func testSingleScreenOnlyMainUsesFullScreen() {
        let r = LayoutEngine.plan([item(1, .main)], screens: [laptop], params: LayoutParams())
        XCTAssertEqual(r.slots[1]!.frame, laptop.visible.insetBy(dx: 8, dy: 8))
    }

    func testOverflowWindowsStackWithSameSize() {
        let items = [item(1, .main), item(2, .reference), item(3, .reference), item(4, .reference)]
        let r = LayoutEngine.plan(items, screens: [laptop], params: LayoutParams())
        XCTAssertEqual(r.slots[2]!.frame, r.slots[3]!.frame)
        XCTAssertEqual(r.slots[2]!.frame, r.slots[4]!.frame)
    }

    func testNoMainPromotesMostRecentReference() {
        let r = LayoutEngine.plan([item(1, .reference), item(2, .reference)], screens: [laptop], params: LayoutParams())
        XCTAssertLessThan(r.slots[1]!.frame.maxX, r.slots[2]!.frame.minX, "most recent reference window is promoted to the main area")
        XCTAssertGreaterThan(r.slots[1]!.frame.width, r.slots[2]!.frame.width)
    }

    func testIgnoredWindowsAreNotPlaced() {
        let r = LayoutEngine.plan([item(1, .main), item(2, .ignore)], screens: [laptop], params: LayoutParams())
        XCTAssertNil(r.slots[2])
    }

    // MARK: Multiple screens

    func testDualScreenRespectsMainScreen() {
        let screens = [laptop, external(x: 1512)]
        var params = LayoutParams()
        params.mainScreen = 1
        let r = LayoutEngine.plan([item(1, .main), item(2, .reference), item(3, .aux)], screens: screens, params: params)
        assertInside([r.slots[1]!.frame], screens[1].visible)
        assertInside([r.slots[2]!.frame, r.slots[3]!.frame], screens[0].visible)
        XCTAssertEqual(r.slots[1]!.screen, 1)
    }

    func testTripleScreenRegions() {
        let screens = [external(x: -2560), external(x: 0), external(x: 2560)]
        var params = LayoutParams()
        params.mainScreen = 1
        let items = [item(1, .main), item(2, .reference), item(3, .reference), item(4, .reference), item(5, .aux)]
        let r = LayoutEngine.plan(items, screens: screens, params: params)
        XCTAssertEqual(r.slots[1]!.screen, 1, "code on the middle screen")
        XCTAssertEqual(r.slots[2]!.screen, 0, "first two reference windows on the left screen")
        XCTAssertEqual(r.slots[3]!.screen, 0)
        XCTAssertEqual(r.slots[4]!.screen, 2, "third reference window goes to the right screen")
        XCTAssertEqual(r.slots[5]!.screen, 2, "aux on the right screen")
        assertNoPartialOverlap(items.map { r.slots[$0.id]!.frame })
    }

    func testDefaultMainScreen() {
        XCTAssertEqual(LayoutEngine.defaultMainScreen([laptop, external(x: 1512)]), 1, "two screens: the larger one")
        XCTAssertEqual(LayoutEngine.defaultMainScreen([external(x: -2560), laptop, external(x: 1512)]), 1, "three screens: the middle one")
    }

    // MARK: Split learning

    func testRatioRoundTripFromDraggedEdge() {
        let r = LayoutEngine.plan([item(1, .main), item(2, .reference)], screens: [laptop], params: LayoutParams())
        guard let boundary = r.slots[1]!.edges[.right] else { return XCTFail("the code window's right edge should be a divider") }
        XCTAssertEqual(boundary.id, "n1.main")
        XCTAssertNotNil(r.slots[2]!.edges[.left], "the reference window's left edge is the same divider")

        // Drag the code window's right edge to 70%
        let total = boundary.parent.width - 8
        let edge = boundary.parent.minX + (total * 0.7).rounded()
        let ratio = LayoutEngine.ratio(for: boundary, edgePosition: edge, gap: 8)
        XCTAssertEqual(ratio, 0.7, accuracy: 0.002)

        var params = LayoutParams()
        params.ratios["n1.main"] = ratio
        let r2 = LayoutEngine.plan([item(1, .main), item(2, .reference)], screens: [laptop], params: params)
        XCTAssertEqual(r2.slots[1]!.frame.maxX, edge, accuracy: 1)
        XCTAssertEqual(r2.slots[2]!.frame.minX, edge + 8, accuracy: 1, "the neighbor moves out of the way")
    }

    func testRatioFromSecondWindowEdge() {
        let r = LayoutEngine.plan([item(1, .main), item(2, .reference)], screens: [laptop], params: LayoutParams())
        let boundary = r.slots[2]!.edges[.left]!
        let total = boundary.parent.width - 8
        let edge = boundary.parent.minX + (total * 0.5).rounded() + 8
        XCTAssertEqual(LayoutEngine.ratio(for: boundary, edgePosition: edge, gap: 8), 0.5, accuracy: 0.002)
    }

    func testRatioIsClamped() {
        let r = LayoutEngine.plan([item(1, .main), item(2, .reference)], screens: [laptop], params: LayoutParams())
        let boundary = r.slots[1]!.edges[.right]!
        XCTAssertEqual(LayoutEngine.ratio(for: boundary, edgePosition: 10_000, gap: 8), 0.8)
        XCTAssertEqual(LayoutEngine.ratio(for: boundary, edgePosition: -10_000, gap: 8), 0.2)
    }

    func testVerticalBoundaryBetweenReferenceAndAux() {
        let r = LayoutEngine.plan([item(1, .main), item(2, .reference), item(3, .aux)], screens: [laptop], params: LayoutParams())
        let bottom = r.slots[2]!.edges[.bottom]
        XCTAssertEqual(bottom?.id, "n1.side")
        XCTAssertEqual(r.slots[3]!.edges[.top]?.id, "n1.side")
        XCTAssertEqual(r.slots[2]!.edges[.left]?.id, "n1.main", "the reference window also inherits the left divider")
    }

    // MARK: Scenes

    func testSceneFramesAreExactAndSameAppStacks() {
        var params = LayoutParams()
        params.sceneFrames = ["com.a#Problem": Placement(screen: 0, x: 0.1, y: 0.1, w: 0.5, h: 0.5)]
        let items = [item(1, .reference, bundle: "com.a", key: "com.a#Problem"),
                     item(2, .reference, bundle: "com.a"),
                     item(3, .main)]
        let r = LayoutEngine.plan(items, screens: [laptop], params: params)
        let v = laptop.visible
        let expected = CGRect(x: (v.minX + 0.1 * v.width).rounded(), y: (v.minY + 0.1 * v.height).rounded(),
                              width: (0.5 * v.width).rounded(), height: (0.5 * v.height).rounded())
        XCTAssertEqual(r.slots[1]!.frame, expected)
        XCTAssertEqual(r.slots[2]!.frame, expected, "other windows of the same app stack on it")
        XCTAssertNotNil(r.slots[3])
        XCTAssertTrue(r.slots[1]!.edges.isEmpty, "scene positions have no draggable dividers")
    }

    func testSceneFrameOnMissingScreenFallsBackToTemplate() {
        var params = LayoutParams()
        params.sceneFrames = ["app.1": Placement(screen: 2, x: 0, y: 0, w: 1, h: 1)]
        let r = LayoutEngine.plan([item(1, .main)], screens: [laptop], params: params)
        XCTAssertEqual(r.slots[1]!.frame, laptop.visible.insetBy(dx: 8, dy: 8))
    }

    // MARK: Region detection

    func testTemplateRegionsCoverAllRoles() {
        let regions = LayoutEngine.templateRegions(screens: [laptop], params: LayoutParams())
        XCTAssertEqual(Set(regions.map { $0.role }), [.main, .reference, .aux])
        let main = regions.first { $0.role == .main }!
        XCTAssertTrue(main.rect.contains(CGPoint(x: 100, y: 500)))
    }
}
