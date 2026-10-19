import Foundation
import CoreGraphics

/// Usage habits, stored in ~/Library/Application Support/SmartTile/habits.json
struct Habits: Codable {
    /// Foreground seconds per app
    var focusSeconds: [String: Double] = [:]
    /// bundle ID → app name
    var appNames: [String: String] = [:]
    /// "n<screen count>|<role>" → [screen index: seconds]: which screen each role is used on
    var roleScreenFocus: [String: [String: Double]] = [:]
    /// window key → [role: votes]: which area the window was dragged into
    var roleVotes: [String: [String: Double]] = [:]
    /// window key → learned role
    var learnedRoles: [String: Role] = [:]
    /// "n<screen count>" → main screen index (where a code window was dragged to)
    var learnedMainScreen: [String: Int] = [:]
    var layoutsApplied: Int = 0
    var ratioAdjustments: Int = 0
    var rolesLearned: Int = 0

    enum CodingKeys: String, CodingKey {
        case focusSeconds, appNames, roleScreenFocus, roleVotes, learnedRoles, learnedMainScreen,
             layoutsApplied, ratioAdjustments, rolesLearned
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        focusSeconds = try c.decodeIfPresent([String: Double].self, forKey: .focusSeconds) ?? [:]
        appNames = try c.decodeIfPresent([String: String].self, forKey: .appNames) ?? [:]
        roleScreenFocus = try c.decodeIfPresent([String: [String: Double]].self, forKey: .roleScreenFocus) ?? [:]
        roleVotes = try c.decodeIfPresent([String: [String: Double]].self, forKey: .roleVotes) ?? [:]
        learnedRoles = try c.decodeIfPresent([String: Role].self, forKey: .learnedRoles) ?? [:]
        learnedMainScreen = try c.decodeIfPresent([String: Int].self, forKey: .learnedMainScreen) ?? [:]
        layoutsApplied = try c.decodeIfPresent(Int.self, forKey: .layoutsApplied) ?? 0
        ratioAdjustments = try c.decodeIfPresent(Int.self, forKey: .ratioAdjustments) ?? 0
        rolesLearned = try c.decodeIfPresent(Int.self, forKey: .rolesLearned) ?? 0
    }
}

/// Reads and writes config, habits and scenes, and holds the learning logic.
final class Store {
    var config: Config
    var habits: Habits
    var sceneBook: SceneBook
    let directory: URL
    var configURL: URL { directory.appendingPathComponent("config.json") }
    var habitsURL: URL { directory.appendingPathComponent("habits.json") }
    var scenesURL: URL { directory.appendingPathComponent("scenes.json") }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        directory = base.appendingPathComponent("SmartTile", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        config = Config.defaults
        habits = Habits()
        sceneBook = SceneBook(scenes: [Scene.makeDefault()], activeID: Scene.defaultID)
        loadConfig()
        loadHabits()
        loadScenes()
    }

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private func backup(_ url: URL) {
        let dest = url.deletingPathExtension().appendingPathExtension("broken.json")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
    }

    // MARK: Config

    func loadConfig() {
        if let data = try? Data(contentsOf: configURL) {
            do {
                config = try JSONDecoder().decode(Config.self, from: data)
            } catch {
                NSLog("SmartTile: failed to parse config.json, using defaults: \(error)")
                config = Config.defaults
            }
        } else {
            config = Config.defaults
            saveConfig()
        }
    }

    func saveConfig() {
        if let data = try? encoder().encode(config) {
            try? data.write(to: configURL, options: .atomic)
        }
    }

    // MARK: Habits

    func loadHabits() {
        guard let data = try? Data(contentsOf: habitsURL) else { return }
        do {
            habits = try JSONDecoder().decode(Habits.self, from: data)
        } catch {
            NSLog("SmartTile: failed to parse habits.json: \(error)")
            backup(habitsURL)
        }
    }

    func saveHabits() {
        if let data = try? encoder().encode(habits) {
            try? data.write(to: habitsURL, options: .atomic)
        }
    }

    /// Clears everything learned (usage time, roles, main screen, every scene's splits);
    /// keeps the layouts saved in scenes.
    func clearHabits() {
        habits = Habits()
        saveHabits()
        for i in sceneBook.scenes.indices { sceneBook.scenes[i].ratios = [:] }
        saveScenes()
    }

    func addFocus(bundleID: String, name: String, seconds: Double) {
        habits.focusSeconds[bundleID, default: 0] += seconds
        habits.appNames[bundleID] = name
    }

    func addRoleScreenFocus(screenCount n: Int, role: Role, screen: Int, seconds: Double) {
        let key = "n\(n)|\(role.rawValue)"
        habits.roleScreenFocus[key, default: [:]]["\(screen)", default: 0] += seconds
    }

    /// Infers the main screen from where code windows are used most: needs at least
    /// 2 minutes of data and more than half of the time on that screen.
    func preferredMainScreen(screenCount n: Int) -> Int? {
        guard n > 1, let d = habits.roleScreenFocus["n\(n)|\(Role.main.rawValue)"] else { return nil }
        let total = d.values.reduce(0, +)
        guard total >= 120, let best = d.max(by: { $0.value < $1.value }),
              let i = Int(best.key), i < n, best.value / total >= 0.5 else { return nil }
        return i
    }

    /// Casts a vote when a window is dragged into an area. Two drags in a row into the same
    /// area switch the window to that role; dragging it back restores the original.
    /// Returns true when the learned role changed.
    func voteRole(key: String, role: Role, natural: Role) -> Bool {
        var votes = habits.roleVotes[key] ?? [:]
        for k in Array(votes.keys) { votes[k] = (votes[k] ?? 0) * 0.5 }
        votes[role.rawValue, default: 0] += 1
        habits.roleVotes[key] = votes
        let current = habits.learnedRoles[key] ?? natural
        guard (votes[role.rawValue] ?? 0) >= 1.4, role != current else { return false }
        if role == natural {
            habits.learnedRoles.removeValue(forKey: key)
        } else {
            habits.learnedRoles[key] = role
        }
        habits.roleVotes[key] = [:]
        saveHabits()
        return true
    }

    /// Forgets learned roles for an app (including its title-identified windows).
    func forgetLearnedRoles(bundleID: String) {
        for key in Array(habits.learnedRoles.keys) where key == bundleID || key.hasPrefix(bundleID + "#") {
            habits.learnedRoles.removeValue(forKey: key)
        }
        for key in Array(habits.roleVotes.keys) where key == bundleID || key.hasPrefix(bundleID + "#") {
            habits.roleVotes.removeValue(forKey: key)
        }
        saveHabits()
    }

    // MARK: Scenes

    func loadScenes() {
        if let data = try? Data(contentsOf: scenesURL) {
            do {
                sceneBook = try JSONDecoder().decode(SceneBook.self, from: data)
            } catch {
                NSLog("SmartTile: failed to parse scenes.json: \(error)")
                backup(scenesURL)
            }
        }
        if !sceneBook.scenes.contains(where: { $0.id == Scene.defaultID }) {
            sceneBook.scenes.insert(Scene.makeDefault(), at: 0)
        }
        // Older versions stored a hard-coded Chinese name for the default scene;
        // clear it so the localized name is shown.
        if let i = sceneBook.scenes.firstIndex(where: { $0.id == Scene.defaultID }),
           sceneBook.scenes[i].name == "日常" {
            sceneBook.scenes[i].name = ""
        }
        if !sceneBook.scenes.contains(where: { $0.id == sceneBook.activeID }) {
            sceneBook.activeID = Scene.defaultID
        }
    }

    func saveScenes() {
        if let data = try? encoder().encode(sceneBook) {
            try? data.write(to: scenesURL, options: .atomic)
        }
    }

    var activeScene: Scene {
        sceneBook.scenes.first { $0.id == sceneBook.activeID } ?? sceneBook.scenes[0]
    }

    func updateScene(id: String, _ change: (inout Scene) -> Void) {
        guard let i = sceneBook.scenes.firstIndex(where: { $0.id == id }) else { return }
        change(&sceneBook.scenes[i])
        saveScenes()
    }

    func updateActiveScene(_ change: (inout Scene) -> Void) {
        updateScene(id: activeScene.id, change)
    }

    func setActiveScene(_ id: String) {
        guard sceneBook.scenes.contains(where: { $0.id == id }) else { return }
        sceneBook.activeID = id
        saveScenes()
    }

    @discardableResult
    func addScene(name: String, copyRatiosFrom source: Scene) -> Scene {
        let scene = Scene(id: UUID().uuidString, name: name, signature: [], layouts: [:], ratios: source.ratios)
        sceneBook.scenes.append(scene)
        sceneBook.activeID = scene.id
        saveScenes()
        return scene
    }

    func deleteScene(id: String) {
        guard id != Scene.defaultID else { return }
        sceneBook.scenes.removeAll { $0.id == id }
        if sceneBook.activeID == id { sceneBook.activeID = Scene.defaultID }
        saveScenes()
    }
}
