import AppKit
import ApplicationServices

// Private but widely used API (Rectangle, yabai, ...): get the CGWindowID of an AXUIElement.
@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: inout CGWindowID) -> AXError

/// Thin wrapper around the macOS Accessibility API.
enum AX {
    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Reading attributes

    static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        copy(el, attr) as? String
    }

    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        copy(el, attr) as? Bool
    }

    static func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        (copy(el, attr) as? [AXUIElement]) ?? []
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = copy(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = copy(el, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = copy(el, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    static func windowID(_ el: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(el, &id) == .success, id != 0 else { return nil }
        return id
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.3)
        return element(appEl, kAXFocusedWindowAttribute)
    }

    // MARK: Changing windows

    static func setFrame(_ w: ManagedWindow, to r: CGRect) {
        // Some apps (Chrome, Electron) animate and lag while AXEnhancedUserInterface is on; turn it off temporarily.
        let appEl = AXUIElementCreateApplication(w.pid)
        AXUIElementSetMessagingTimeout(appEl, 0.5)
        let enhanced = bool(appEl, "AXEnhancedUserInterface") == true
        if enhanced {
            AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }
        // Size, then position, then size again: avoids being clamped by a smaller screen when moving across displays.
        setSize(w.element, r.size)
        setPosition(w.element, r.origin)
        setSize(w.element, r.size)
        if enhanced {
            AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    private static func setSize(_ el: AXUIElement, _ size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) {
            AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v)
        }
    }

    private static func setPosition(_ el: AXUIElement, _ point: CGPoint) {
        var p = point
        if let v = AXValueCreate(.cgPoint, &p) {
            AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v)
        }
    }

    static func focus(_ w: ManagedWindow) {
        AXUIElementSetAttributeValue(w.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: w.pid)?.activate(options: [.activateIgnoringOtherApps])
    }

    // MARK: Enumerating windows

    /// All visible standard windows on the current Space, ordered front to back.
    static func allWindows(excludingPID myPID: pid_t) -> [ManagedWindow] {
        let order = onscreenOrder()
        var result: [ManagedWindow] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular, !app.isHidden,
                  app.processIdentifier != myPID,
                  let bid = app.bundleIdentifier else { continue }
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appEl, 0.3)
            for el in elements(appEl, kAXWindowsAttribute) {
                guard let wid = windowID(el), let z = order[wid] else { continue }
                guard string(el, kAXSubroleAttribute) == kAXStandardWindowSubrole else { continue }
                if bool(el, kAXMinimizedAttribute) == true { continue }
                if bool(el, "AXFullScreen") == true { continue }
                guard let f = frame(el), f.width >= 200, f.height >= 120 else { continue }
                result.append(ManagedWindow(
                    id: wid, element: el, pid: app.processIdentifier, bundleID: bid,
                    appName: app.localizedName ?? bid,
                    title: string(el, kAXTitleAttribute) ?? "",
                    frame: f, zIndex: z))
            }
        }
        return result.sorted { $0.zIndex < $1.zIndex }
    }

    /// CGWindowList returns on-screen windows front to back. No Screen Recording permission
    /// is needed because we don't read window names from it.
    private static func onscreenOrder() -> [CGWindowID: Int] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [:] }
        var map: [CGWindowID: Int] = [:]
        for (i, info) in list.enumerated() {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let num = info[kCGWindowNumber as String] as? Int else { continue }
            map[CGWindowID(num)] = i
        }
        return map
    }
}

/// Screen geometry: converts Cocoa coordinates (bottom-left origin) to AX coordinates (top-left origin).
enum Geometry {
    /// All screens, sorted left to right.
    static func screens() -> [ScreenInfo] {
        guard let primary = NSScreen.screens.first else { return [] }
        let h = primary.frame.height
        func flip(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
        }
        return NSScreen.screens
            .map { ScreenInfo(frame: flip($0.frame), visible: flip($0.visibleFrame)) }
            .sorted { a, b in
                a.frame.minX != b.frame.minX ? a.frame.minX < b.frame.minX : a.frame.minY < b.frame.minY
            }
    }

    static func screenIndex(of rect: CGRect, in screens: [ScreenInfo]) -> Int {
        var best = 0
        var bestArea: CGFloat = 0
        for (i, s) in screens.enumerated() {
            let inter = s.frame.intersection(rect)
            let area = inter.isNull ? 0 : inter.width * inter.height
            if area > bestArea { bestArea = area; best = i }
        }
        if bestArea > 0 { return best }
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (i, s) in screens.enumerated() {
            let d = hypot(s.frame.midX - c.x, s.frame.midY - c.y)
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }

    static func normalize(_ r: CGRect, in v: CGRect) -> CGRect {
        func clamp(_ x: CGFloat) -> CGFloat { min(max(x, 0), 1) }
        return CGRect(x: clamp((r.minX - v.minX) / v.width),
                      y: clamp((r.minY - v.minY) / v.height),
                      width: clamp(r.width / v.width),
                      height: clamp(r.height / v.height))
    }

    static func denormalize(_ p: Placement, in v: CGRect) -> CGRect {
        CGRect(x: (v.minX + CGFloat(p.x) * v.width).rounded(),
               y: (v.minY + CGFloat(p.y) * v.height).rounded(),
               width: (CGFloat(p.w) * v.width).rounded(),
               height: (CGFloat(p.h) * v.height).rounded())
    }
}
