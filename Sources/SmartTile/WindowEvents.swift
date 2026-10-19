import AppKit
import ApplicationServices

/// Listens to window events of every app (created, moved, resized, focus changed)
/// through AXObserver, instead of polling.
final class WindowEvents {
    enum Kind {
        case created, moved, resized, focused
    }

    var handler: ((Kind, AXUIElement) -> Void)?
    private var observers: [pid_t: AXObserver] = [:]

    func isObserving(_ pid: pid_t) -> Bool {
        observers[pid] != nil
    }

    /// Attaches observers to all regular apps (skipping ones already observed). Apps that
    /// just launched may not be ready yet; they are retried later.
    func observeAllRunning(excluding myPID: pid_t) {
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != myPID {
            observe(pid: app.processIdentifier)
        }
        // Drop apps that have quit
        let alive = Set(NSWorkspace.shared.runningApplications.map { $0.processIdentifier })
        for pid in Array(observers.keys) where !alive.contains(pid) {
            unobserve(pid: pid)
        }
    }

    func observe(pid: pid_t) {
        guard observers[pid] == nil else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, axObserverCallback, &created) == .success, let observer = created else { return }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var registered = false
        for name in [kAXWindowCreatedNotification, kAXWindowMovedNotification,
                     kAXWindowResizedNotification, kAXFocusedWindowChangedNotification] {
            let err = AXObserverAddNotification(observer, appElement, name as CFString, refcon)
            if err == .success || err == .notificationAlreadyRegistered { registered = true }
        }
        guard registered else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), CFRunLoopMode.defaultMode)
        observers[pid] = observer
    }

    func unobserve(pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), CFRunLoopMode.defaultMode)
    }

    fileprivate func dispatch(_ notification: String, _ element: AXUIElement) {
        let kind: Kind
        switch notification {
        case kAXWindowCreatedNotification: kind = .created
        case kAXWindowMovedNotification: kind = .moved
        case kAXWindowResizedNotification: kind = .resized
        case kAXFocusedWindowChangedNotification: kind = .focused
        default: return
        }
        handler?(kind, element)
    }
}

private func axObserverCallback(_ observer: AXObserver, _ element: AXUIElement,
                                _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon = refcon else { return }
    let events = Unmanaged<WindowEvents>.fromOpaque(refcon).takeUnretainedValue()
    events.dispatch(notification as String, element)
}
