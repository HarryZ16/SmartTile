import AppKit

/// Core controller: handles window events, records usage habits, learns from manual
/// adjustments, arranges windows, and manages scenes and undo.
final class Controller {
    private struct UndoEntry {
        let frames: [CGWindowID: CGRect]
        let ratio: (sceneID: String, key: String, old: Double?)?
    }

    let store: Store
    var onStatus: ((String) -> Void)?

    private let events = WindowEvents()
    private(set) var windows: [ManagedWindow] = []
    private var lastFocused: [CGWindowID: Date] = [:]
    /// Where each window was last placed (including which edges are dividers); used to
    /// tell which divider the user dragged
    private var placedSlots: [CGWindowID: Slot] = [:]
    /// Ignore move/resize events for a short while after we moved a window ourselves
    private var suppressUntil: [CGWindowID: Date] = [:]
    private var manualWork: [CGWindowID: DispatchWorkItem] = [:]
    private var undoStack: [UndoEntry] = []
    /// After a scene is picked manually, don't auto-switch until the window set changes
    private var manualSceneLock: Set<String>?
    /// Windows the user moved or resized by hand. Automatic arranging leaves them where they
    /// are until the user explicitly arranges again (⌃⌥L, picking a scene, display change).
    private var held = Set<CGWindowID>()
    /// Extra windows of an app (same identity as a window that is already arranged), e.g. an
    /// image viewer opened from a chat app. They stay where the app put them.
    private var floating = Set<CGWindowID>()
    private var timers: [Timer] = []
    private var screenWork: DispatchWorkItem?
    private var lastScreenSignature = ""
    private let myPID = getpid()

    var canUndo: Bool { !undoStack.isEmpty }
    var heldCount: Int { held.count }

    init(store: Store) {
        self.store = store
    }

    // MARK: - Startup

    func start() {
        lastScreenSignature = screenSignature()
        events.handler = { [weak self] kind, element in self?.handleEvent(kind, element) }

        timers.append(Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.trackFocus() })
        timers.append(Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.store.saveHabits() })
        // Maintenance: start observing once trusted; retry apps that weren't ready earlier
        timers.append(Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.maintainObservers() })

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.scheduleScreenCheck() }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleScreenCheck()
        }
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.appLaunched(app)
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.events.unobserve(pid: app.processIdentifier)
        }

        maintainObservers()
    }

    private func maintainObservers() {
        guard AX.isTrusted(prompt: false) else { return }
        events.observeAllRunning(excluding: myPID)
    }

    private func appLaunched(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular, app.processIdentifier != myPID else { return }
        let pid = app.processIdentifier
        // AX may not be ready right after launch: observe a bit later and place the windows it opened
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.events.observe(pid: pid)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, self.store.config.autoPlaceNewWindows else { return }
            let ids = self.refreshWindows().filter { $0.pid == pid && self.placedSlots[$0.id] == nil }.map { $0.id }
            self.placeNewWindows(ids)
        }
    }

    // MARK: - Window events

    private func handleEvent(_ kind: WindowEvents.Kind, _ element: AXUIElement) {
        guard let id = AX.windowID(element) else { return }
        switch kind {
        case .focused:
            lastFocused[id] = Date()
        case .created:
            guard store.config.autoPlaceNewWindows else { return }
            // Let the app restore its own window size first
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.placeNewWindows([id])
            }
        case .moved, .resized:
            if (suppressUntil[id] ?? .distantPast) > Date() { return }
            // Dragging fires many events; handle once things settle for 0.8s
            manualWork[id]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.manualWork[id] = nil
                self?.handleManualChange(id)
            }
            manualWork[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        }
    }

    // MARK: - Roles

    private func matchingRule(bundleID: String, base: Role, title: String) -> TitleRule? {
        guard !title.isEmpty else { return nil }
        let rules = store.config.titleRules.filter { !$0.contains.isEmpty }
        // App-specific rules first
        let ordered = rules.filter { $0.bundleID != nil } + rules.filter { $0.bundleID == nil }
        for rule in ordered {
            if let b = rule.bundleID, b != bundleID { continue }
            if let scope = rule.appRole, scope != base { continue }
            if title.localizedCaseInsensitiveContains(rule.contains) { return rule }
        }
        return nil
    }

    func baseRole(_ bundleID: String) -> Role {
        store.config.appRoles[bundleID] ?? .reference
    }

    /// Role precedence: ignore > learned role > title rule > app role > default (reference).
    func classify(bundleID: String, title: String, useLearned: Bool = true) -> (role: Role, key: String) {
        let base = baseRole(bundleID)
        if base == .ignore { return (.ignore, bundleID) }
        var role = base
        var key = bundleID
        if let rule = matchingRule(bundleID: bundleID, base: base, title: title) {
            role = rule.role
            key = bundleID + "#" + rule.contains
        }
        if useLearned, let learned = store.habits.learnedRoles[key] {
            role = learned
        }
        return (role, key)
    }

    func setAppRole(_ role: Role, for bundleID: String) {
        store.config.appRoles[bundleID] = role
        store.saveConfig()
        store.forgetLearnedRoles(bundleID: bundleID)
    }

    /// Identifies a window separately by a title keyword (e.g. a "problem" browser window),
    /// so scenes and learning treat it apart from the app's other windows.
    func pinWindow(bundleID: String, keyword: String, role: Role) {
        store.config.titleRules.removeAll { $0.bundleID == bundleID && $0.contains == keyword }
        store.config.titleRules.insert(TitleRule(contains: keyword, role: role, appRole: nil, bundleID: bundleID), at: 0)
        store.saveConfig()
    }

    // MARK: - Window list

    /// Refreshes the window list, sorted by most recent focus then z-order, with role and
    /// key computed for each window.
    @discardableResult
    func refreshWindows() -> [ManagedWindow] {
        let raw = AX.allWindows(excludingPID: myPID)
        windows = raw.map { w -> ManagedWindow in
            var w = w
            let c = classify(bundleID: w.bundleID, title: w.title)
            w.role = c.role
            w.key = c.key
            return w
        }.sorted { a, b in
            let fa = lastFocused[a.id] ?? .distantPast
            let fb = lastFocused[b.id] ?? .distantPast
            if fa != fb { return fa > fb }
            return a.zIndex < b.zIndex
        }
        let alive = Set(windows.map { $0.id })
        suppressUntil = suppressUntil.filter { alive.contains($0.key) }
        // Windows on other Spaces aren't listed, so only prune these sets when they grow large
        if held.count > 300 { held.formIntersection(alive) }
        if floating.count > 300 { floating.formIntersection(alive) }
        if lastFocused.count > 400 {
            let keep = lastFocused.sorted { $0.value > $1.value }.prefix(200)
            lastFocused = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        return windows
    }

    private func ensureTrusted() -> Bool {
        if AX.isTrusted(prompt: false) { return true }
        _ = AX.isTrusted(prompt: true)
        onStatus?(L("Accessibility permission required"))
        return false
    }

    // MARK: - Layout parameters

    func mainScreenIndex(_ screens: [ScreenInfo]) -> Int {
        let n = screens.count
        if let i = store.config.mainScreenIndex, i >= 0, i < n { return i }
        if let i = store.habits.learnedMainScreen["n\(n)"], i >= 0, i < n { return i }
        if let i = store.preferredMainScreen(screenCount: n), i < n { return i }
        return LayoutEngine.defaultMainScreen(screens)
    }

    func mainScreenDescription(_ screens: [ScreenInfo]) -> String {
        let n = screens.count
        guard n > 1 else { return "—" }
        let i = mainScreenIndex(screens) + 1
        if let m = store.config.mainScreenIndex, m < n { return L("Screen %d (manual)", i) }
        if let m = store.habits.learnedMainScreen["n\(n)"], m < n { return L("Screen %d (you dragged code there)", i) }
        if store.preferredMainScreen(screenCount: n) != nil { return L("Screen %d (by usage time)", i) }
        return L("Screen %d (default)", i)
    }

    func layoutParams(_ screens: [ScreenInfo]) -> LayoutParams {
        let scene = store.activeScene
        return LayoutParams(gap: CGFloat(max(0, store.config.gap)),
                            ratios: scene.ratios,
                            singleScreenMainRatio: store.config.singleScreenMainRatio,
                            mainScreen: mainScreenIndex(screens),
                            sceneFrames: scene.layouts["n\(screens.count)"] ?? [:])
    }

    /// Windows that take part in the layout. With "Keep Extra Windows Next to Their App" on,
    /// only one window per identity is arranged; the others stay where their app put them.
    private func layoutCandidates(_ wins: [ManagedWindow]) -> [ManagedWindow] {
        guard store.config.floatExtraWindows else { return wins }
        let items = wins.map {
            WindowGrouping.Item(id: $0.id, key: $0.key, placed: placedSlots[$0.id] != nil,
                                floating: floating.contains($0.id))
        }
        let primary = Set(WindowGrouping.primaries(items).values)
        for w in wins {
            if primary.contains(w.id) { floating.remove(w.id) } else { floating.insert(w.id) }
        }
        return wins.filter { primary.contains($0.id) }
    }

    private func plan(_ wins: [ManagedWindow], screens: [ScreenInfo]) -> LayoutResult {
        let items = wins.map { LayoutItem(id: $0.id, bundleID: $0.bundleID, key: $0.key, role: $0.role) }
        return LayoutEngine.plan(items, screens: screens, params: layoutParams(screens))
    }

    // MARK: - Arranging

    /// ⌃⌥L: arrange everything, including windows the user moved by hand.
    func layoutAll() {
        relayout(autoScene: true, ratioUndo: nil, message: nil, releaseHeld: true)
    }

    /// - releaseHeld: true for explicit user actions; false for automatic ones, which leave
    ///   hand-placed windows where they are.
    private func relayout(autoScene: Bool, ratioUndo: (sceneID: String, key: String, old: Double?)?,
                          message: String?, releaseHeld: Bool) {
        guard ensureTrusted() else { return }
        if releaseHeld { held.removeAll() }
        let wins = refreshWindows()
        var switchedTo: String?
        if autoScene { switchedTo = autoSelectScene(wins) }
        let screens = Geometry.screens()
        guard !screens.isEmpty else { return }
        let candidates = layoutCandidates(wins)
        // Held windows still occupy their slot in the plan, so the others don't move into it,
        // but they are not moved themselves.
        let moved = apply(plan(candidates, screens: screens), to: candidates, only: nil, skip: held,
                          ratioUndo: ratioUndo)
        store.habits.layoutsApplied += 1
        if let message = message {
            onStatus?(message)
        } else if let scene = switchedTo {
            onStatus?(L("Scene “%@” · arranged %d windows", scene, moved))
        } else {
            onStatus?(L("Arranged %d windows", moved))
        }
    }

    /// Places only newly appeared windows, leaving the others alone. A new window of an app
    /// that already has a window of the same identity (e.g. an image opened from WeChat) is a
    /// companion: it stays where the app put it, next to its parent.
    private func placeNewWindows(_ ids: [CGWindowID]) {
        guard !ids.isEmpty, AX.isTrusted(prompt: false) else { return }
        let wins = refreshWindows()
        let byID = Dictionary(uniqueKeysWithValues: wins.map { ($0.id, $0) })
        let newIDs = Set(ids)
        // Identities that already have a window on screen
        var claimed = Set(wins.filter { !newIDs.contains($0.id) && !floating.contains($0.id) && $0.role != .ignore }
                              .map { $0.key })
        var targets = Set<CGWindowID>()
        for id in ids.sorted() {   // oldest first
            guard let w = byID[id], placedSlots[id] == nil, !floating.contains(id), w.role != .ignore else { continue }
            if store.config.floatExtraWindows && claimed.contains(w.key) {
                floating.insert(id)
                if let parent = wins.first(where: { $0.key == w.key && $0.id != id && !floating.contains($0.id) }) {
                    keepBeside(w, parent: parent)
                }
                continue
            }
            claimed.insert(w.key)
            targets.insert(id)
        }
        guard !targets.isEmpty else { return }
        let screens = Geometry.screens()
        guard !screens.isEmpty else { return }
        let candidates = layoutCandidates(wins)
        apply(plan(candidates, screens: screens), to: candidates, only: targets, skip: held, ratioUndo: nil)
    }

    /// A companion window that opened on a different display than its parent is moved next
    /// to the parent, keeping its size. Otherwise it stays exactly where the app put it.
    private func keepBeside(_ w: ManagedWindow, parent: ManagedWindow) {
        let screens = Geometry.screens()
        guard screens.count > 1 else { return }
        let ps = Geometry.screenIndex(of: parent.frame, in: screens)
        guard Geometry.screenIndex(of: w.frame, in: screens) != ps else { return }
        let v = screens[ps].visible
        let gap = CGFloat(max(0, store.config.gap))
        let width = min(w.frame.width, v.width)
        let height = min(w.frame.height, v.height)
        var x = parent.frame.maxX + gap
        if x + width > v.maxX { x = parent.frame.minX - gap - width }
        if x < v.minX { x = parent.frame.midX - width / 2 }
        x = min(max(x, v.minX), v.maxX - width)
        let y = min(max(parent.frame.minY, v.minY), v.maxY - height)
        suppressUntil[w.id] = Date().addingTimeInterval(1.5)
        AX.setFrame(w, to: CGRect(x: x, y: y, width: width, height: height))
    }

    @discardableResult
    private func apply(_ result: LayoutResult, to wins: [ManagedWindow], only: Set<CGWindowID>?,
                       skip: Set<CGWindowID>, ratioUndo: (sceneID: String, key: String, old: Double?)?) -> Int {
        let inScope = wins.filter {
            result.slots[$0.id] != nil && (only?.contains($0.id) ?? true) && !skip.contains($0.id)
        }
        let targets = inScope.filter { !$0.frame.isClose(to: result.slots[$0.id]!.frame, tol: 2) }

        if !targets.isEmpty || ratioUndo != nil {
            var frames: [CGWindowID: CGRect] = [:]
            for w in wins { frames[w.id] = w.frame }
            undoStack.append(UndoEntry(frames: frames, ratio: ratioUndo))
            if undoStack.count > 15 { undoStack.removeFirst() }
        }

        let until = Date().addingTimeInterval(1.5)
        for w in targets {
            suppressUntil[w.id] = until
            manualWork[w.id]?.cancel()
            AX.setFrame(w, to: result.slots[w.id]!.frame)
        }
        for w in inScope { placedSlots[w.id] = result.slots[w.id] }
        return targets.count
    }

    /// ⌃⌥Z: restore the state before the last arrangement (or split adjustment).
    func undo() {
        guard ensureTrusted() else { return }
        guard let entry = undoStack.popLast() else {
            NSSound.beep()
            onStatus?(L("Nothing to undo"))
            return
        }
        if let r = entry.ratio {
            store.updateScene(id: r.sceneID) { scene in
                if let old = r.old { scene.ratios[r.key] = old } else { scene.ratios.removeValue(forKey: r.key) }
            }
        }
        let until = Date().addingTimeInterval(1.5)
        var count = 0
        for w in refreshWindows() {
            guard let f = entry.frames[w.id], !w.frame.isClose(to: f, tol: 2) else { continue }
            suppressUntil[w.id] = until
            AX.setFrame(w, to: f)
            count += 1
        }
        placedSlots.removeAll()
        onStatus?(L("Undone (%d windows)", count))
    }

    // MARK: - Learning from manual adjustments

    /// A mouse drag in the last 3 seconds means the user did it (not the app resizing itself).
    private func userIsDragging() -> Bool {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDragged) < 3
    }

    private func handleManualChange(_ id: CGWindowID) {
        guard userIsDragging() else { return }
        guard let w = refreshWindows().first(where: { $0.id == id }), w.role != .ignore else { return }

        // Leave the window where the user put it: automatic arranging skips it until ⌃⌥L.
        if held.insert(id).inserted {
            onStatus?(L("Keeping “%@” where you put it. ⌃⌥L re-arranges it", w.appName))
        }
        // Companion windows float freely; there is nothing to learn from them.
        if floating.contains(id) { return }
        guard store.config.learnFromManualMoves else { return }
        guard let slot = placedSlots[id] else {
            learnFromMove(w)
            return
        }

        let f = w.frame
        let s = slot.frame
        let moved: [Edge: CGFloat] = [
            .left: f.minX - s.minX, .right: f.maxX - s.maxX,
            .top: f.minY - s.minY, .bottom: f.maxY - s.maxY,
        ]
        let changed = moved.filter { abs($0.value) > 16 }
        let still = moved.filter { abs($0.value) <= 8 }
        // A divider drag moves exactly one edge, and that edge is shared with a neighbor.
        // Anything else (moving the window, macOS shrinking it on another display, dragging
        // an outer edge) is not a split change.
        if changed.count == 1, still.count == 3, let edge = changed.keys.first,
           let boundary = slot.edges[edge] {
            let position: CGFloat
            switch edge {
            case .left: position = f.minX
            case .right: position = f.maxX
            case .top: position = f.minY
            case .bottom: position = f.maxY
            }
            adjustRatio(boundary, edgePosition: position)
            return
        }
        if hypot(f.midX - s.midX, f.midY - s.midY) > 60 {
            learnFromMove(w)
        }
    }

    /// The user dragged the divider between two areas: remember the new split and move the
    /// neighbors right away. The dragged window itself is held, so it stays as the user left it.
    private func adjustRatio(_ boundary: Boundary, edgePosition: CGFloat) {
        let gap = CGFloat(max(0, store.config.gap))
        let r = LayoutEngine.ratio(for: boundary, edgePosition: edgePosition, gap: gap)
        let scene = store.activeScene
        let old = scene.ratios[boundary.id]
        store.updateActiveScene { $0.ratios[boundary.id] = r }
        store.habits.ratioAdjustments += 1
        let pct = Int((r * 100).rounded())
        relayout(autoScene: false, ratioUndo: (scene.id, boundary.id, old),
                 message: L("Split set to %d%% : %d%% (⌃⌥Z to undo)", pct, 100 - pct), releaseHeld: false)
    }

    /// The user dragged a window into another area: two times in a row and it belongs there.
    /// Dragging a code window to another screen makes that the main screen.
    private func learnFromMove(_ w: ManagedWindow) {
        let screens = Geometry.screens()
        guard !screens.isEmpty else { return }
        let n = screens.count
        let params = layoutParams(screens)
        let dropScreen = Geometry.screenIndex(of: w.frame, in: screens)

        if w.role == .main && n > 1 && dropScreen != params.mainScreen && store.config.mainScreenIndex == nil {
            store.habits.learnedMainScreen["n\(n)"] = dropScreen
            store.saveHabits()
            onStatus?(L("Main screen is now screen %d. Press ⌃⌥L to re-arrange", dropScreen + 1))
            return
        }

        let center = CGPoint(x: w.frame.midX, y: w.frame.midY)
        let regions = LayoutEngine.templateRegions(screens: screens, params: params)
        guard let region = regions.first(where: { $0.rect.contains(center) }) else { return }
        let natural = classify(bundleID: w.bundleID, title: w.title, useLearned: false).role
        if store.voteRole(key: w.key, role: region.role, natural: natural) {
            store.habits.rolesLearned += 1
            onStatus?(L("Learned: “%@” now goes to the %@ area", displayName(forKey: w.key), region.role.short))
        }
    }

    func displayName(forKey key: String) -> String {
        let parts = key.split(separator: "#", maxSplits: 1).map(String.init)
        let bid = parts.first ?? key
        let name = store.habits.appNames[bid]
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: bid).first?.localizedName
            ?? bid
        return parts.count > 1 ? "\(name) · \(parts[1])" : name
    }

    // MARK: - Scenes

    /// Window set used to recognize scenes: main and reference windows only (whether music
    /// or chat is open doesn't matter).
    private func signatureKeys(_ wins: [ManagedWindow]) -> Set<String> {
        Set(wins.filter { $0.role == .main || $0.role == .reference }.map { $0.key })
    }

    /// Picks the scene that best matches the open windows. Returns the new scene's name,
    /// or nil if nothing changed.
    private func autoSelectScene(_ wins: [ManagedWindow]) -> String? {
        guard store.config.autoSwitchScene else { return nil }
        let keys = signatureKeys(wins)
        if let lock = manualSceneLock {
            if lock == keys { return nil }
            manualSceneLock = nil
        }
        var bestID = Scene.defaultID
        var bestScore = 0.0
        for scene in store.sceneBook.scenes where !scene.signature.isEmpty {
            let sig = Set(scene.signature)
            let union = Double(sig.union(keys).count)
            let score = union > 0 ? Double(sig.intersection(keys).count) / union : 0
            if score > bestScore { bestScore = score; bestID = scene.id }
        }
        if bestScore < 0.5 { bestID = Scene.defaultID }
        guard bestID != store.sceneBook.activeID else { return nil }
        store.setActiveScene(bestID)
        placedSlots.removeAll()
        return store.activeScene.displayName
    }

    func selectScene(_ id: String) {
        store.setActiveScene(id)
        manualSceneLock = signatureKeys(refreshWindows())
        placedSlots.removeAll()
        relayout(autoScene: false, ratioUndo: nil, message: L("Switched to scene “%@”", store.activeScene.displayName),
                 releaseHeld: true)
    }

    /// ⌃⌥N: switch to the next scene.
    func nextScene() {
        let scenes = store.sceneBook.scenes
        guard scenes.count > 1, let i = scenes.firstIndex(where: { $0.id == store.sceneBook.activeID }) else {
            NSSound.beep()
            onStatus?(L("Only one scene. Create another from the menu"))
            return
        }
        selectScene(scenes[(i + 1) % scenes.count].id)
    }

    /// ⌃⌥S: save every window's current position to the current scene.
    func saveLayoutToScene() {
        guard ensureTrusted() else { return }
        let screens = Geometry.screens()
        guard !screens.isEmpty else { return }
        let wins = refreshWindows()
        var frames: [String: Placement] = [:]
        // Only arranged windows are saved; companion windows keep floating next to their app
        for w in layoutCandidates(wins) where w.role != .ignore && frames[w.key] == nil {
            let idx = Geometry.screenIndex(of: w.frame, in: screens)
            let r = Geometry.normalize(w.frame, in: screens[idx].visible)
            frames[w.key] = Placement(screen: idx, x: Double(r.minX), y: Double(r.minY),
                                      w: Double(r.width), h: Double(r.height))
            placedSlots[w.id] = Slot(frame: w.frame, edges: [:], role: w.role, screen: idx)
            held.remove(w.id)
        }
        let signature = Array(signatureKeys(wins)).sorted()
        store.updateActiveScene { scene in
            scene.layouts["n\(screens.count)"] = frames
            scene.signature = signature
        }
        manualSceneLock = Set(signature)
        onStatus?(L("Saved to scene “%@” (%d windows)", store.activeScene.displayName, frames.count))
    }

    func createScene(named name: String) {
        store.addScene(name: name, copyRatiosFrom: store.activeScene)
        saveLayoutToScene()
    }

    func renameActiveScene(_ name: String) {
        store.updateActiveScene { $0.name = name }
    }

    func clearActiveSceneLayout() {
        store.updateActiveScene { scene in
            scene.layouts = [:]
            scene.signature = []
            scene.ratios = [:]
        }
        relayout(autoScene: false, ratioUndo: nil,
                 message: L("Cleared scene “%@”; back to the template layout", store.activeScene.displayName),
                 releaseHeld: true)
    }

    func deleteActiveScene() {
        let name = store.activeScene.displayName
        store.deleteScene(id: store.sceneBook.activeID)
        relayout(autoScene: false, ratioUndo: nil, message: L("Deleted scene “%@”", name), releaseHeld: true)
    }

    // MARK: - Usage time

    private func trackFocus() {
        guard AX.isTrusted(prompt: false) else { return }
        // No input for 90 seconds: the user is away, don't count
        if let any = CGEventType(rawValue: ~0),
           CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any) > 90 { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != myPID, app.activationPolicy == .regular,
              let bid = app.bundleIdentifier else { return }
        store.addFocus(bundleID: bid, name: app.localizedName ?? bid, seconds: 1)

        guard let el = AX.focusedWindow(pid: app.processIdentifier) else { return }
        if let id = AX.windowID(el) { lastFocused[id] = Date() }
        if let f = AX.frame(el) {
            let screens = Geometry.screens()
            guard screens.count > 1 else { return }
            let idx = Geometry.screenIndex(of: f, in: screens)
            let r = classify(bundleID: bid, title: AX.string(el, kAXTitleAttribute) ?? "").role
            store.addRoleScreenFocus(screenCount: screens.count, role: r, screen: idx, seconds: 1)
        }
    }

    // MARK: - Display changes

    private func screenSignature() -> String {
        Geometry.screens().map { "\(Int($0.frame.width))x\(Int($0.frame.height))@\(Int($0.frame.minX)),\(Int($0.frame.minY))" }
            .joined(separator: "|")
    }

    private func scheduleScreenCheck() {
        screenWork?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.handleScreenChange() }
        screenWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    private func handleScreenChange() {
        let sig = screenSignature()
        guard sig != lastScreenSignature else { return }
        lastScreenSignature = sig
        placedSlots.removeAll()
        undoStack.removeAll()   // old coordinates are meaningless on a new screen setup
        if store.config.autoLayoutOnScreenChange {
            layoutAll()
        }
    }

    // MARK: - Switching windows

    private func frontWindowID() -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let el = AX.focusedWindow(pid: app.processIdentifier) else { return nil }
        return AX.windowID(el)
    }

    /// Title of the frontmost window (for "Identify Current Window by Title").
    func frontWindowTitle(pid: pid_t) -> String? {
        guard let el = AX.focusedWindow(pid: pid) else { return nil }
        return AX.string(el, kAXTitleAttribute)
    }

    /// ⌃⌥1/2/3: focus a window of a role; pressing again cycles through that role.
    func focusRole(_ r: Role) {
        guard ensureTrusted() else { return }
        let group = refreshWindows().filter { $0.role == r }
        guard !group.isEmpty else { NSSound.beep(); return }
        var target = group[0]
        if let front = frontWindowID(), let i = group.firstIndex(where: { $0.id == front }) {
            target = group[(i + 1) % group.count]
        }
        AX.focus(target)
    }

    /// ⌃⌥Space: pop up a list of windows grouped by role, with titles.
    func showSwitcher() {
        guard ensureTrusted() else { return }
        let wins = refreshWindows()
        let menu = NSMenu(title: L("Switch Window"))
        menu.autoenablesItems = false
        var count = 0
        for r in [Role.main, .reference, .aux, .ignore] {
            let group = wins.filter { $0.role == r }
            if group.isEmpty { continue }
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            let header = NSMenuItem(title: r.label, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for w in group {
                count += 1
                let title = w.title.isEmpty ? w.appName : "\(w.appName) — \(Self.truncate(w.title, 60))"
                let item = ActionItem(title, key: count <= 9 ? "\(count)" : "") { AX.focus(w) }
                item.keyEquivalentModifierMask = []
                if let icon = NSRunningApplication(processIdentifier: w.pid)?.icon?.copy() as? NSImage {
                    icon.size = NSSize(width: 16, height: 16)
                    item.image = icon
                }
                menu.addItem(item)
            }
        }
        guard count > 0 else { NSSound.beep(); return }
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        let picked = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        if !picked { previous?.activate(options: []) }
    }

    static func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }

    // MARK: - Stats snapshot

    static func ratioLabel(_ id: String) -> String {
        let names: [String: String] = [
            "n1.main": L("1 screen · code area width"),
            "n1.side": L("1 screen · reference / aux split"),
            "n2.mains": L("2 screens · two code windows"),
            "n2.side": L("2 screens · reference / aux split"),
            "n2.refs": L("2 screens · two reference windows"),
            "n2.auxs": L("2 screens · two aux windows"),
        ]
        if let n = names[id] { return n }
        if id.hasSuffix(".mains") { return L("3+ screens · two code windows") }
        if id.hasSuffix(".aux.side") { return L("3+ screens · right screen reference / aux split") }
        if id.hasSuffix(".refs") { return L("3+ screens · two reference windows") }
        if id.hasSuffix(".auxs") { return L("3+ screens · two aux windows") }
        return id
    }

    func snapshot() -> StatsSnapshot {
        let screens = Geometry.screens()
        let n = screens.count
        let h = store.habits
        let apps = h.focusSeconds.sorted { $0.value > $1.value }.prefix(15).map { entry in
            AppStat(id: entry.key, name: h.appNames[entry.key] ?? entry.key,
                    role: classify(bundleID: entry.key, title: "").role.short, seconds: entry.value)
        }
        let scene = store.activeScene
        let ratios = scene.ratios.sorted { $0.key < $1.key }.map { entry in
            RatioStat(id: entry.key, label: Self.ratioLabel(entry.key), value: entry.value)
        }
        let roles = h.learnedRoles.sorted { $0.key < $1.key }.map { entry in
            RoleStat(id: entry.key, name: displayName(forKey: entry.key), role: entry.value.short)
        }
        let scenes = store.sceneBook.scenes.map { s in
            SceneStat(id: s.id, name: s.displayName, windows: s.layouts["n\(n)"]?.count ?? 0,
                      active: s.id == scene.id)
        }
        return StatsSnapshot(trusted: AX.isTrusted(prompt: false), screenCount: n,
                             mainScreen: mainScreenDescription(screens), sceneName: scene.displayName,
                             apps: Array(apps), ratios: ratios, roles: roles, scenes: scenes,
                             layouts: h.layoutsApplied, ratioAdjustments: h.ratioAdjustments,
                             rolesLearned: h.rolesLearned, dataPath: store.directory.path)
    }
}
