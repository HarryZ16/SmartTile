import AppKit
import SwiftUI
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let store = Store()
    private lazy var controller = Controller(store: store)
    private var statsWindow: NSWindow?
    private var statusResetWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: "SmartTile")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeft
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        controller.onStatus = { [weak self] message in self?.flash(message) }
        registerHotKeys()

        // Shows the system permission prompt on first launch
        _ = AX.isTrusted(prompt: true)
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveHabits()
    }

    // MARK: Hotkeys

    private func registerHotKeys() {
        let mods = controlKey | optionKey
        let hk = HotKeyCenter.shared
        hk.register(keyCode: kVK_ANSI_L, modifiers: mods) { [weak self] in self?.controller.layoutAll() }
        hk.register(keyCode: kVK_ANSI_Z, modifiers: mods) { [weak self] in self?.controller.undo() }
        hk.register(keyCode: kVK_Space, modifiers: mods) { [weak self] in self?.controller.showSwitcher() }
        hk.register(keyCode: kVK_ANSI_S, modifiers: mods) { [weak self] in self?.controller.saveLayoutToScene() }
        hk.register(keyCode: kVK_ANSI_N, modifiers: mods) { [weak self] in self?.controller.nextScene() }
        hk.register(keyCode: kVK_ANSI_1, modifiers: mods) { [weak self] in self?.controller.focusRole(.main) }
        hk.register(keyCode: kVK_ANSI_2, modifiers: mods) { [weak self] in self?.controller.focusRole(.reference) }
        hk.register(keyCode: kVK_ANSI_3, modifiers: mods) { [weak self] in self?.controller.focusRole(.aux) }
    }

    /// Briefly shows a message next to the menu bar icon.
    private func flash(_ message: String) {
        statusItem.button?.title = " " + message
        statusResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.statusItem.button?.title = "" }
        statusResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // MARK: Menu (rebuilt every time it opens so it always reflects the current state)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let cfg = store.config
        let ctrlOpt: NSEvent.ModifierFlags = [.control, .option]

        if !AX.isTrusted(prompt: false) {
            menu.addItem(ActionItem(L("⚠️ Accessibility access not granted. Click to open Settings")) {
                AX.openAccessibilitySettings()
            })
            menu.addItem(.separator())
        }

        menu.addItem(ActionItem(L("Arrange Windows Now"), key: "l", modifiers: ctrlOpt) { [weak self] in
            self?.controller.layoutAll()
        })
        let undoItem = ActionItem(L("Undo Last Arrangement"), key: "z", modifiers: ctrlOpt) { [weak self] in
            self?.controller.undo()
        }
        undoItem.isEnabled = controller.canUndo
        menu.addItem(undoItem)
        if controller.heldCount > 0 {
            let info = NSMenuItem(title: L("%d windows you moved stay put. ⌃⌥L re-arranges them", controller.heldCount),
                                  action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        menu.addItem(ActionItem(L("Window Switcher"), key: " ", modifiers: ctrlOpt) { [weak self] in
            DispatchQueue.main.async { self?.controller.showSwitcher() }
        })

        let focusMenu = NSMenu()
        focusMenu.addItem(ActionItem(L("Main Area"), key: "1", modifiers: ctrlOpt) { [weak self] in self?.controller.focusRole(.main) })
        focusMenu.addItem(ActionItem(L("Reference Area"), key: "2", modifiers: ctrlOpt) { [weak self] in self?.controller.focusRole(.reference) })
        focusMenu.addItem(ActionItem(L("Aux Area"), key: "3", modifiers: ctrlOpt) { [weak self] in self?.controller.focusRole(.aux) })
        menu.addItem(submenuItem(L("Jump to Area (press again to cycle)"), focusMenu))

        menu.addItem(.separator())
        menu.addItem(submenuItem(L("Scene: %@", store.activeScene.displayName), sceneMenu(ctrlOpt)))

        // Frontmost app
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != getpid(),
           let bid = front.bundleIdentifier {
            let name = front.localizedName ?? bid
            menu.addItem(submenuItem(L("“%@” Role: %@", name, controller.baseRole(bid).short),
                                     appMenu(front, bundleID: bid)))
        }

        // Main screen
        let screenCount = Geometry.screens().count
        if screenCount > 1 {
            let sub = NSMenu()
            let auto = ActionItem(L("Automatic (from your habits)")) { [weak self] in self?.setMainScreen(nil) }
            auto.state = cfg.mainScreenIndex == nil ? .on : .off
            sub.addItem(auto)
            for i in 0..<screenCount {
                let title: String
                if i == 0 { title = L("Screen %d (leftmost)", i + 1) }
                else if i == screenCount - 1 { title = L("Screen %d (rightmost)", i + 1) }
                else { title = L("Screen %d", i + 1) }
                let item = ActionItem(title) { [weak self] in self?.setMainScreen(i) }
                item.state = cfg.mainScreenIndex == i ? .on : .off
                sub.addItem(item)
            }
            sub.addItem(.separator())
            sub.addItem(ActionItem(L("Forget Main Screen Learned from Dragging")) { [weak self] in
                guard let self = self else { return }
                self.store.habits.learnedMainScreen.removeValue(forKey: "n\(screenCount)")
                self.store.saveHabits()
                self.flash(L("Main screen now follows usage time"))
            })
            menu.addItem(submenuItem(L("Main Screen (for code)"), sub))
        }

        menu.addItem(.separator())
        menu.addItem(toggle(L("Auto-place New Windows"), cfg.autoPlaceNewWindows) { $0.autoPlaceNewWindows.toggle() })
        menu.addItem(toggle(L("Keep Extra Windows Next to Their App"), cfg.floatExtraWindows) { $0.floatExtraWindows.toggle() })
        menu.addItem(toggle(L("Re-arrange When Displays Change"), cfg.autoLayoutOnScreenChange) { $0.autoLayoutOnScreenChange.toggle() })
        menu.addItem(toggle(L("Learn from Manual Adjustments"), cfg.learnFromManualMoves) { $0.learnFromManualMoves.toggle() })
        let login = ActionItem(L("Launch at Login")) { [weak self] in self?.toggleLoginItem() }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(ActionItem(L("Habits & Learning…")) { [weak self] in self?.showStats() })
        menu.addItem(ActionItem(L("Edit Rules File…")) { [weak self] in
            guard let self = self else { return }
            self.store.saveConfig()
            NSWorkspace.shared.open(self.store.configURL)
        })
        menu.addItem(ActionItem(L("Reload Rules")) { [weak self] in
            self?.store.loadConfig()
            self?.flash(L("Rules reloaded"))
        })
        menu.addItem(ActionItem(L("Clear Learning Data…")) { [weak self] in self?.confirmClear() })
        menu.addItem(.separator())
        menu.addItem(ActionItem(L("Quit SmartTile"), key: "q", modifiers: [.command]) {
            NSApp.terminate(nil)
        })
    }

    private func submenuItem(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func sceneMenu(_ ctrlOpt: NSEvent.ModifierFlags) -> NSMenu {
        let sub = NSMenu()
        let active = store.activeScene
        for scene in store.sceneBook.scenes {
            let item = ActionItem(scene.displayName) { [weak self] in self?.controller.selectScene(scene.id) }
            item.state = scene.id == active.id ? .on : .off
            sub.addItem(item)
        }
        sub.addItem(.separator())
        sub.addItem(ActionItem(L("Save Current Layout to “%@”", active.displayName), key: "s", modifiers: ctrlOpt) { [weak self] in
            self?.controller.saveLayoutToScene()
        })
        sub.addItem(ActionItem(L("Next Scene"), key: "n", modifiers: ctrlOpt) { [weak self] in
            self?.controller.nextScene()
        })
        sub.addItem(ActionItem(L("New Scene from Current Layout…")) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self,
                      let name = self.prompt(L("New Scene"),
                                             message: L("Name this layout, e.g. “Coding”, “LeetCode” or “Class”."),
                                             value: "") else { return }
                self.controller.createScene(named: name)
            }
        })
        sub.addItem(ActionItem(L("Rename “%@”…", active.displayName)) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self,
                      let name = self.prompt(L("Rename Scene"), message: "", value: active.displayName) else { return }
                self.controller.renameActiveScene(name)
            }
        })
        sub.addItem(ActionItem(L("Clear Saved Layout and Splits of “%@”", active.displayName)) { [weak self] in
            self?.controller.clearActiveSceneLayout()
        })
        if active.id != Scene.defaultID {
            sub.addItem(ActionItem(L("Delete “%@”", active.displayName)) { [weak self] in
                self?.controller.deleteActiveScene()
            })
        }
        sub.addItem(.separator())
        sub.addItem(toggle(L("Switch Scenes Automatically Based on Open Windows"), store.config.autoSwitchScene) {
            $0.autoSwitchScene.toggle()
        })
        return sub
    }

    private func appMenu(_ app: NSRunningApplication, bundleID bid: String) -> NSMenu {
        let name = app.localizedName ?? bid
        let sub = NSMenu()
        let current = controller.baseRole(bid)
        for r in Role.allCases {
            let item = ActionItem(r.label) { [weak self] in
                self?.controller.setAppRole(r, for: bid)
                self?.flash(L("“%@” set to %@", name, r.short))
            }
            item.state = r == current ? .on : .off
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let pid = app.processIdentifier
        sub.addItem(ActionItem(L("Identify Current Window by Title…")) { [weak self] in
            DispatchQueue.main.async { self?.pinFrontWindow(pid: pid, bundleID: bid, appName: name) }
        })
        sub.addItem(ActionItem(L("Forget Learned Roles for “%@”", name)) { [weak self] in
            self?.store.forgetLearnedRoles(bundleID: bid)
            self?.flash(L("Forgotten"))
        })
        return sub
    }

    private func pinFrontWindow(pid: pid_t, bundleID: String, appName: String) {
        let title = controller.frontWindowTitle(pid: pid) ?? ""
        let suggestion = Controller.truncate(title, 30).replacingOccurrences(of: "…", with: "")
        let message = L("“%@” windows whose title contains this keyword will be remembered separately (their own role and scene position).\n\nCurrent window title: %@", appName, title)
        guard let keyword = prompt(L("Identify Window by Title"), message: message, value: suggestion) else { return }
        let role = controller.classify(bundleID: bundleID, title: title).role
        controller.pinWindow(bundleID: bundleID, keyword: keyword, role: role == .ignore ? .reference : role)
        flash(L("Now identified separately: %@", keyword))
    }

    private func toggle(_ title: String, _ on: Bool, _ change: @escaping (inout Config) -> Void) -> NSMenuItem {
        let item = ActionItem(title) { [weak self] in
            guard let self = self else { return }
            change(&self.store.config)
            self.store.saveConfig()
        }
        item.state = on ? .on : .off
        return item
    }

    private func setMainScreen(_ index: Int?) {
        store.config.mainScreenIndex = index
        store.saveConfig()
        controller.layoutAll()
    }

    private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                flash(L("Launch at login turned off"))
            } else {
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                    flash(L("Allow SmartTile in System Settings"))
                } else {
                    flash(L("Launch at login turned on"))
                }
            }
        } catch {
            flash(L("Failed. Install to Applications first with ./build.sh --install"))
            NSLog("SmartTile: failed to change launch-at-login: \(error)")
        }
    }

    private func prompt(_ title: String, message: String, value: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: L("OK"))
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func confirmClear() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Clear all learning data?")
        alert.informativeText = L("Usage time, learned roles, the main screen preference and every scene's splits will be deleted. Window positions saved in scenes and the rules file are kept.")
        alert.addButton(withTitle: L("Clear"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            store.clearHabits()
            flash(L("Learning data cleared"))
        }
    }

    // MARK: Stats window

    private func showStats() {
        let view = StatsView(s: controller.snapshot())
        if statsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 680),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "SmartTile"
            w.isReleasedWhenClosed = false
            statsWindow = w
        }
        statsWindow?.contentView = NSHostingView(rootView: view)
        statsWindow?.center()
        NSApp.activate(ignoringOtherApps: true)
        statsWindow?.makeKeyAndOrderFront(nil)
    }
}
