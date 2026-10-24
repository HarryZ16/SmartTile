import CoreGraphics

// MARK: - Layout data types

enum Edge: String {
    case left, right, top, bottom   // AX coordinates: top = minY, bottom = maxY
}

enum Axis {
    case horizontal   // side by side
    case vertical     // stacked
}

/// The divider between two areas. When the user drags a window edge, it is used to
/// compute the new split ratio.
struct Boundary {
    let id: String          // ratio name, e.g. "n1.main"
    let parent: CGRect      // the area being split
    let axis: Axis
    let first: Bool         // the window is on the left/top side of the divider
}

/// Where a window was placed, and which of its edges are draggable dividers.
struct Slot {
    var frame: CGRect
    var edges: [Edge: Boundary]
    var role: Role
    var screen: Int
}

/// The area a role occupies in the template (used to tell which area a window was dragged into).
struct RegionInfo {
    let role: Role
    let screen: Int
    let rect: CGRect
}

/// Layout input: a window's identity and role (passed in order of importance).
struct LayoutItem {
    let id: CGWindowID
    let bundleID: String
    let key: String
    let role: Role
}

struct LayoutParams {
    var gap: CGFloat = 8
    var ratios: [String: Double] = [:]
    var singleScreenMainRatio: Double = 0.6
    var mainScreen: Int = 0
    /// Exact positions saved in the current scene (window key → position)
    var sceneFrames: [String: Placement] = [:]
}

struct LayoutResult {
    var slots: [CGWindowID: Slot] = [:]
}

/// An area that can be split further; remembers which of its edges are dividers.
struct Region {
    var rect: CGRect
    var edges: [Edge: Boundary] = [:]

    func split(_ axis: Axis, ratio: Double, id: String, gap: CGFloat) -> (Region, Region) {
        switch axis {
        case .horizontal:
            let total = rect.width - gap
            let w1 = (total * CGFloat(ratio)).rounded()
            var a = Region(rect: CGRect(x: rect.minX, y: rect.minY, width: w1, height: rect.height), edges: edges)
            let bx = rect.minX + w1 + gap
            var b = Region(rect: CGRect(x: bx, y: rect.minY, width: rect.maxX - bx, height: rect.height), edges: edges)
            a.edges[.right] = Boundary(id: id, parent: rect, axis: .horizontal, first: true)
            b.edges[.left] = Boundary(id: id, parent: rect, axis: .horizontal, first: false)
            return (a, b)
        case .vertical:
            let total = rect.height - gap
            let h1 = (total * CGFloat(ratio)).rounded()
            var a = Region(rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h1), edges: edges)
            let by = rect.minY + h1 + gap
            var b = Region(rect: CGRect(x: rect.minX, y: by, width: rect.width, height: rect.maxY - by), edges: edges)
            a.edges[.bottom] = Boundary(id: id, parent: rect, axis: .vertical, first: true)
            b.edges[.top] = Boundary(id: id, parent: rect, axis: .vertical, first: false)
            return (a, b)
        }
    }
}

// MARK: - Layout engine (pure functions, no system APIs, easy to unit test)

/// Rules:
/// 1. Windows with an exact position saved in the current scene go back there; other
///    windows of the same app / role stack on top of it (same size).
/// 2. Remaining windows fill a template by role. The splits between areas can be
///    adjusted by dragging window edges (and are remembered):
///    - 1 screen: main area on the left (60% by default); reference above aux on the right.
///    - 2 screens: main area on the main screen; reference left and aux right on the other.
///    - 3+ screens: main area on the main screen, reference on the screen to its left,
///      aux plus overflow reference windows on the screen to its right.
/// 3. Windows that don't fit stack on the same slot with exactly the same size.
enum LayoutEngine {
    static func defaultRatio(_ id: String, params: LayoutParams) -> Double {
        if id == "n1.main" { return min(max(params.singleScreenMainRatio, 0.2), 0.8) }
        if id.hasSuffix(".side") { return 0.62 }
        return 0.5
    }

    static func ratio(_ id: String, params: LayoutParams) -> Double {
        params.ratios[id] ?? defaultRatio(id, params: params)
    }

    /// Derives the split ratio from a dragged edge position (clamped to 20%–80%).
    static func ratio(for b: Boundary, edgePosition p: CGFloat, gap: CGFloat) -> Double {
        let start = b.axis == .horizontal ? b.parent.minX : b.parent.minY
        let length = b.axis == .horizontal ? b.parent.width : b.parent.height
        let total = max(length - gap, 1)
        let r = b.first ? (p - start) / total : (p - gap - start) / total
        return Double(min(max(r, 0.2), 0.8))
    }

    /// Default main screen: the middle one with 3+ screens, otherwise the largest.
    static func defaultMainScreen(_ screens: [ScreenInfo]) -> Int {
        let n = screens.count
        if n >= 3 { return n / 2 }
        var best = 0
        var bestArea: CGFloat = -1
        for (i, s) in screens.enumerated() where s.frame.width * s.frame.height > bestArea {
            bestArea = s.frame.width * s.frame.height
            best = i
        }
        return best
    }

    static func plan(_ items: [LayoutItem], screens: [ScreenInfo], params: LayoutParams) -> LayoutResult {
        var builder = Builder(params: params)
        builder.run(items, screens: screens)
        return builder.result
    }

    /// The area of each role, assuming windows of all three roles are present.
    static func templateRegions(screens: [ScreenInfo], params: LayoutParams) -> [RegionInfo] {
        var p = params
        p.sceneFrames = [:]
        let fake = [
            LayoutItem(id: 1, bundleID: "_main", key: "_main", role: .main),
            LayoutItem(id: 2, bundleID: "_ref", key: "_ref", role: .reference),
            LayoutItem(id: 3, bundleID: "_aux", key: "_aux", role: .aux),
        ]
        let result = plan(fake, screens: screens, params: p)
        return fake.compactMap { item in
            result.slots[item.id].map { RegionInfo(role: item.role, screen: $0.screen, rect: $0.frame) }
        }
    }
}

private struct Builder {
    let params: LayoutParams
    var result = LayoutResult()

    init(params: LayoutParams) {
        self.params = params
    }

    private var gap: CGFloat { params.gap }

    private func ratio(_ id: String) -> Double {
        LayoutEngine.ratio(id, params: params)
    }

    mutating func run(_ items: [LayoutItem], screens: [ScreenInfo]) {
        guard !screens.isEmpty else { return }
        let n = screens.count

        // 1. Windows with an exact position in the scene
        var usedKeys = Set<String>()
        var sceneSlotByBundle: [String: Slot] = [:]
        var sceneSlotByRole: [Role: Slot] = [:]
        var rest: [LayoutItem] = []
        for item in items where item.role != .ignore {
            if !usedKeys.contains(item.key), let p = params.sceneFrames[item.key], p.screen >= 0, p.screen < n {
                usedKeys.insert(item.key)
                let v = screens[p.screen].visible
                let frame = CGRect(x: (v.minX + CGFloat(p.x) * v.width).rounded(),
                                   y: (v.minY + CGFloat(p.y) * v.height).rounded(),
                                   width: (CGFloat(p.w) * v.width).rounded(),
                                   height: (CGFloat(p.h) * v.height).rounded())
                let slot = Slot(frame: frame, edges: [:], role: item.role, screen: p.screen)
                result.slots[item.id] = slot
                if sceneSlotByBundle[item.bundleID] == nil { sceneSlotByBundle[item.bundleID] = slot }
                if sceneSlotByRole[item.role] == nil { sceneSlotByRole[item.role] = slot }
            } else {
                rest.append(item)
            }
        }

        // 2. Others: stack onto a scene slot of the same app/role, otherwise use the template
        var mains: [LayoutItem] = []
        var refs: [LayoutItem] = []
        var auxs: [LayoutItem] = []
        for item in rest {
            if let s = sceneSlotByBundle[item.bundleID] ?? sceneSlotByRole[item.role] {
                result.slots[item.id] = Slot(frame: s.frame, edges: [:], role: item.role, screen: s.screen)
                continue
            }
            switch item.role {
            case .main: mains.append(item)
            case .reference: refs.append(item)
            case .aux: auxs.append(item)
            case .ignore: break
            }
        }

        let sceneHasMain = sceneSlotByRole[.main] != nil
        // No code window: promote the most recently used reference window to the main area
        if mains.isEmpty && !sceneHasMain {
            if !refs.isEmpty { mains.append(refs.removeFirst()) }
            else if !auxs.isEmpty { mains.append(auxs.removeFirst()) }
        }

        let areas = screens.map { Region(rect: $0.visible.insetBy(dx: gap, dy: gap)) }

        switch n {
        case 1:
            if refs.isEmpty && auxs.isEmpty {
                place(mains, in: areas[0], maxVisible: 1, pairID: "n1.mains", screen: 0)
            } else if mains.isEmpty && !sceneHasMain {
                side(refs, auxs, in: areas[0], maxRef: 1, maxAux: 1, prefix: "n1", screen: 0)
            } else {
                let (a, b) = areas[0].split(.horizontal, ratio: ratio("n1.main"), id: "n1.main", gap: gap)
                place(mains, in: a, maxVisible: 1, pairID: "n1.mains", screen: 0)
                side(refs, auxs, in: b, maxRef: 1, maxAux: 1, prefix: "n1", screen: 0)
            }

        case 2:
            let m = min(max(params.mainScreen, 0), 1)
            let o = 1 - m
            place(mains, in: areas[m], maxVisible: areas[m].rect.width >= 2200 ? 2 : 1, pairID: "n2.mains", screen: m)
            side(refs, auxs, in: areas[o], maxRef: 2, maxAux: 2, prefix: "n2", screen: o)

        default:
            let p = "n\(n)"
            let m = min(max(params.mainScreen, 0), n - 1)
            let refIdx = m > 0 ? m - 1 : m + 1
            let others = (0..<n).filter { $0 != m && $0 != refIdx }
            let auxIdx = others.min { abs($0 - m) < abs($1 - m) } ?? refIdx
            place(mains, in: areas[m], maxVisible: areas[m].rect.width >= 2200 ? 2 : 1, pairID: "\(p).mains", screen: m)
            let shownRefs = Array(refs.prefix(2))
            let extraRefs = Array(refs.dropFirst(2))
            place(shownRefs, in: areas[refIdx], maxVisible: 2, pairID: "\(p).refs", screen: refIdx)
            side(extraRefs, auxs, in: areas[auxIdx], maxRef: 2, maxAux: 2, prefix: "\(p).aux", screen: auxIdx)
        }
    }

    /// Places windows in an area: up to `maxVisible` (max 2) share it, the rest stack on the
    /// first slot with the same size.
    private mutating func place(_ items: [LayoutItem], in region: Region, maxVisible: Int, pairID: String, screen: Int) {
        guard !items.isEmpty else { return }
        let k = max(1, min(maxVisible, items.count, 2))
        var slots = [region]
        if k == 2 {
            let axis: Axis = region.rect.width >= region.rect.height ? .horizontal : .vertical
            let (a, b) = region.split(axis, ratio: ratio(pairID), id: pairID, gap: gap)
            slots = [a, b]
        }
        for (i, item) in items.enumerated() {
            let r = slots[i < k ? i : 0]
            result.slots[item.id] = Slot(frame: r.rect, edges: r.edges, role: item.role, screen: screen)
        }
    }

    /// Reference and aux share an area: reference left/top, aux right/bottom; the split is
    /// adjustable (62% / 38% by default).
    private mutating func side(_ refs: [LayoutItem], _ auxs: [LayoutItem], in region: Region,
                               maxRef: Int, maxAux: Int, prefix: String, screen: Int) {
        if !refs.isEmpty && !auxs.isEmpty {
            let axis: Axis = region.rect.width >= region.rect.height * 1.2 ? .horizontal : .vertical
            let (a, b) = region.split(axis, ratio: ratio("\(prefix).side"), id: "\(prefix).side", gap: gap)
            place(refs, in: a, maxVisible: maxRef, pairID: "\(prefix).refs", screen: screen)
            place(auxs, in: b, maxVisible: maxAux, pairID: "\(prefix).auxs", screen: screen)
        } else if !refs.isEmpty {
            place(refs, in: region, maxVisible: maxRef, pairID: "\(prefix).refs", screen: screen)
        } else {
            place(auxs, in: region, maxVisible: maxAux, pairID: "\(prefix).auxs", screen: screen)
        }
    }
}

// MARK: - Window grouping

/// Decides which window of each identity (key) takes part in the layout when extra windows
/// of an app are left floating. Pure function, unit tested.
enum WindowGrouping {
    struct Item {
        let id: CGWindowID
        let key: String
        /// Already placed by SmartTile
        let placed: Bool
        /// Currently treated as a floating companion window
        let floating: Bool
    }

    /// The primary window id for each key: prefer a window that isn't floating, then one that
    /// was already placed, then the oldest (window ids grow over time, so the lowest id is the
    /// window that was opened first, e.g. the main WeChat window rather than an image viewer).
    /// If every window of a key is floating (its main window was closed), the oldest floating
    /// one becomes the primary again.
    static func primaries(_ items: [Item]) -> [String: CGWindowID] {
        func better(_ a: Item, than b: Item) -> Bool {
            if a.floating != b.floating { return !a.floating }
            if a.placed != b.placed { return a.placed }
            return a.id < b.id
        }
        var best: [String: Item] = [:]
        for item in items {
            if let current = best[item.key], !better(item, than: current) { continue }
            best[item.key] = item
        }
        return best.mapValues { $0.id }
    }
}
