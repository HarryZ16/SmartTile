import Foundation
import CoreGraphics
import ApplicationServices

/// A window's role decides which area of the layout it goes to.
enum Role: String, Codable, CaseIterable {
    case main        // main work area: code editors, terminals
    case reference   // reference area: browsers, documents, PDFs
    case aux         // auxiliary area: music, chat, mail
    case ignore      // not managed

    var label: String {
        switch self {
        case .main: return L("Main (code / terminal)")
        case .reference: return L("Reference (browser / docs)")
        case .aux: return L("Aux (music / chat)")
        case .ignore: return L("Don't manage")
        }
    }

    var short: String {
        switch self {
        case .main: return L("Code")
        case .reference: return L("Reference")
        case .aux: return L("Aux")
        case .ignore: return L("Ignored")
        }
    }
}

/// Title rule: when a window title contains `contains`, give it `role` and remember
/// that window separately from the app's other windows.
/// - `appRole`: only applies to apps whose default role equals this (e.g. browsers only).
/// - `bundleID`: only applies to this app (created by "Identify Current Window by Title").
struct TitleRule: Codable {
    var contains: String
    var role: Role
    var appRole: Role?
    var bundleID: String?
}

struct Config: Codable {
    var appRoles: [String: Role]
    var titleRules: [TitleRule]
    var gap: Double
    var singleScreenMainRatio: Double
    var autoPlaceNewWindows: Bool
    var autoLayoutOnScreenChange: Bool
    var learnFromManualMoves: Bool
    var autoSwitchScene: Bool
    /// Extra windows of an app (same identity as one already arranged) are left where the
    /// app opens them instead of being arranged.
    var floatExtraWindows: Bool
    var mainScreenIndex: Int?

    enum CodingKeys: String, CodingKey {
        case appRoles, titleRules, gap, singleScreenMainRatio, autoPlaceNewWindows,
             autoLayoutOnScreenChange, learnFromManualMoves, autoSwitchScene, floatExtraWindows, mainScreenIndex
    }

    static let defaults = Config(
        appRoles: [
            // Main
            "com.microsoft.VSCode": .main,
            "com.microsoft.VSCodeInsiders": .main,
            "com.todesktop.230313mzl4w4u92": .main,   // Cursor
            "com.exafunction.windsurf": .main,
            "dev.zed.Zed": .main,
            "com.apple.dt.Xcode": .main,
            "com.jetbrains.intellij": .main,
            "com.jetbrains.intellij.ce": .main,
            "com.jetbrains.pycharm": .main,
            "com.jetbrains.pycharm.ce": .main,
            "com.jetbrains.goland": .main,
            "com.jetbrains.CLion": .main,
            "com.sublimetext.4": .main,
            "com.apple.Terminal": .main,
            "com.googlecode.iterm2": .main,
            "dev.warp.Warp-Stable": .main,
            "com.mitchellh.ghostty": .main,
            "net.kovidgoyal.kitty": .main,
            "com.github.wez.wezterm": .main,
            // Reference
            "com.google.Chrome": .reference,
            "com.apple.Safari": .reference,
            "company.thebrowser.Browser": .reference,   // Arc
            "org.mozilla.firefox": .reference,
            "com.microsoft.edgemac": .reference,
            "com.brave.Browser": .reference,
            "com.apple.Preview": .reference,
            "com.readdle.PDFExpert-Mac": .reference,
            "com.adobe.Reader": .reference,
            "com.microsoft.Word": .reference,
            "notion.id": .reference,
            "md.obsidian": .reference,
            "com.apple.Notes": .reference,
            "com.goodnotesapp.x": .reference,
            // Aux
            "com.spotify.client": .aux,
            "com.apple.Music": .aux,
            "com.netease.163music": .aux,
            "com.tencent.QQMusicMac": .aux,
            "com.tencent.xinWeChat": .aux,
            "com.tencent.qq": .aux,
            "com.hnc.Discord": .aux,
            "com.tinyspeck.slackmacgap": .aux,
            "com.apple.MobileSMS": .aux,
            "com.apple.mail": .aux,
            "com.microsoft.Outlook": .aux,
            "com.apple.finder": .aux,
            "com.apple.iCal": .aux,
            // Not managed (fixed-size or unsuitable for resizing)
            "com.apple.systempreferences": .ignore,
            "com.apple.calculator": .ignore,
            "com.apple.ActivityMonitor": .ignore,
        ],
        titleRules: [
            TitleRule(contains: "LeetCode", role: .reference, appRole: .reference),
            TitleRule(contains: "力扣", role: .reference, appRole: .reference),            // LeetCode China
            TitleRule(contains: "YouTube Music", role: .aux, appRole: .reference),
            TitleRule(contains: "YouTube", role: .aux, appRole: .reference),
            TitleRule(contains: "bilibili", role: .aux, appRole: .reference),
            TitleRule(contains: "哔哩哔哩", role: .aux, appRole: .reference),              // bilibili
            TitleRule(contains: "Spotify", role: .aux, appRole: .reference),
            TitleRule(contains: "网易云音乐", role: .aux, appRole: .reference),            // NetEase Cloud Music
        ],
        gap: 8,
        singleScreenMainRatio: 0.6,
        autoPlaceNewWindows: true,
        autoLayoutOnScreenChange: true,
        learnFromManualMoves: true,
        autoSwitchScene: true,
        floatExtraWindows: true,
        mainScreenIndex: nil
    )
}

extension Config {
    // Custom decoding: missing keys fall back to defaults so the file is easy to edit
    // by hand; unknown (old) keys are ignored.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.defaults
        appRoles = try c.decodeIfPresent([String: Role].self, forKey: .appRoles) ?? d.appRoles
        titleRules = try c.decodeIfPresent([TitleRule].self, forKey: .titleRules) ?? d.titleRules
        gap = try c.decodeIfPresent(Double.self, forKey: .gap) ?? d.gap
        singleScreenMainRatio = try c.decodeIfPresent(Double.self, forKey: .singleScreenMainRatio) ?? d.singleScreenMainRatio
        autoPlaceNewWindows = try c.decodeIfPresent(Bool.self, forKey: .autoPlaceNewWindows) ?? d.autoPlaceNewWindows
        autoLayoutOnScreenChange = try c.decodeIfPresent(Bool.self, forKey: .autoLayoutOnScreenChange) ?? d.autoLayoutOnScreenChange
        learnFromManualMoves = try c.decodeIfPresent(Bool.self, forKey: .learnFromManualMoves) ?? d.learnFromManualMoves
        autoSwitchScene = try c.decodeIfPresent(Bool.self, forKey: .autoSwitchScene) ?? d.autoSwitchScene
        floatExtraWindows = try c.decodeIfPresent(Bool.self, forKey: .floatExtraWindows) ?? d.floatExtraWindows
        mainScreenIndex = try c.decodeIfPresent(Int.self, forKey: .mainScreenIndex)
    }
}

/// Snapshot of a manageable window. `frame` uses Accessibility coordinates
/// (origin at the top-left of the primary screen, y grows downward).
struct ManagedWindow {
    let id: CGWindowID
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String
    let appName: String
    let title: String
    let frame: CGRect
    let zIndex: Int          // lower = closer to the front
    var role: Role = .reference
    /// Window identity: the bundle ID, or "bundleID#keyword" when a title rule matches.
    /// Used by scenes and learning.
    var key: String = ""
}

struct ScreenInfo {
    let frame: CGRect     // AX coordinates
    let visible: CGRect   // excluding menu bar and Dock, AX coordinates
}

/// A window position on a screen, as fractions of that screen's visible area.
struct Placement: Codable, Equatable {
    var screen: Int
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

/// A scene is a complete layout: its own area splits plus (optionally) exact
/// positions for specific windows.
struct Scene: Codable {
    var id: String
    /// Empty for the built-in default scene, which shows a localized name.
    var name: String
    /// Main/reference windows that were open when the layout was saved; used to
    /// pick the scene automatically.
    var signature: [String]
    /// "n<screen count>" → window key → position
    var layouts: [String: [String: Placement]]
    /// Area splits, e.g. "n1.main" → 0.65
    var ratios: [String: Double]

    static let defaultID = "default"

    static func makeDefault() -> Scene {
        Scene(id: defaultID, name: "", signature: [], layouts: [:], ratios: [:])
    }

    var displayName: String {
        name.isEmpty ? L("Everyday") : name
    }
}

struct SceneBook: Codable {
    var scenes: [Scene]
    var activeID: String
}

extension CGRect {
    func isClose(to o: CGRect, tol: CGFloat = 4) -> Bool {
        abs(minX - o.minX) <= tol && abs(minY - o.minY) <= tol &&
            abs(width - o.width) <= tol && abs(height - o.height) <= tol
    }
}
