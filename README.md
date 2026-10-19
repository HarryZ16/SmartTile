<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="SmartTile icon">
</p>

<h1 align="center">SmartTile</h1>

<p align="center"><b>English</b> | <a href="README.zh-CN.md">简体中文</a></p>

A macOS menu bar app that arranges your windows automatically based on what you're using, and learns from how you adjust them.

- **Role-based tiling**: code editors, browsers/docs, and music/chat each get their own area, on one screen or across several displays.
- **Learns splits**: drag the edge between two windows and the new split is remembered. Neighboring windows move out of the way immediately.
- **Learns roles**: drag a window into another area twice and it stays there from then on.
- **Scenes**: save layouts such as "Coding", "LeetCode" or "Class". SmartTile switches to the matching scene automatically based on which windows are open.
- **Window switcher**: windows grouped by role with their titles, so you can tell several browser windows apart.
- **Follows the system language**: English and Simplified Chinese.

All data stays on your Mac.

## Requirements

- macOS 13 Ventura or later
- Xcode or the Xcode Command Line Tools (`xcode-select --install`)

## Build and install

```bash
git clone <your-repo-url> SmartTile
cd SmartTile
./build.sh --install
```

On first launch, grant Accessibility access in **System Settings → Privacy & Security → Accessibility**.

The first run of `build.sh` creates a local self-signed certificate ("SmartTile Dev") in your login keychain. macOS may ask for your password to trust it. If it asks whether `codesign` may access the keychain, choose **Always Allow**. With a stable signature, you don't have to re-grant Accessibility access after every rebuild. If the certificate can't be created, the script falls back to ad-hoc signing.

| Command | What it does |
|---|---|
| `./build.sh` | Build `build/SmartTile.app` |
| `./build.sh --install` | Build, copy to `/Applications`, launch |
| `./build.sh --reset` | Also reset the Accessibility permission (use after a signing change) |
| `./build.sh --test` | Run the unit tests first |
| `swift test` | Run the unit tests (with only the Command Line Tools installed, run them in Xcode with ⌘U) |

## Hotkeys

| Hotkey | Action |
|---|---|
| ⌃⌥L | Arrange windows now |
| ⌃⌥Z | Undo the last arrangement or split change (up to 15 steps) |
| ⌃⌥Space | Window switcher (grouped by role, press a number to pick) |
| ⌃⌥1 / 2 / 3 | Focus the main / reference / aux area; press again to cycle |
| ⌃⌥S | Save the current layout to the current scene |
| ⌃⌥N | Next scene |

## How it arranges windows

Every window has a role:

| Role | Default apps |
|---|---|
| Main | VS Code, Cursor, Xcode, JetBrains IDEs, terminals |
| Reference | Browsers, PDF readers, Notion, Obsidian, unknown apps |
| Aux | Spotify, Apple Music, chat apps, Mail, Finder |

Browser windows are also classified by title. For example, YouTube goes to aux and LeetCode to reference.

| Screens | Default layout |
|---|---|
| 1 | Main on the left (60%); reference above aux on the right |
| 2 | Main on the main screen; reference left and aux right on the other |
| 3+ | Main on the main screen, reference on the screen to its left, aux and extra reference windows on the screen to its right |

Windows that don't fit stack on the same slot with exactly the same size. Use ⌃⌥Space to switch between them.

## What it learns

| You... | It learns |
|---|---|
| drag the edge between two windows | the **split ratio**, saved immediately; neighbors move out of the way (⌃⌥Z to undo) |
| drag a window into another area twice in a row | that window's **role**; drag it back to undo |
| drag a code window to another display | the **main screen** |
| spend most coding time on one display | the **main screen** (from usage time; dragging wins) |
| use some windows more recently than others | which windows get the visible slots |

Only mouse adjustments are learned. Apps resizing their own windows are ignored, and dragging an outer screen edge isn't learned.

Data lives in `~/Library/Application Support/SmartTile/`:

| File | Contents |
|---|---|
| `config.json` | Rules (editable) |
| `habits.json` | Learned habits |
| `scenes.json` | Scenes |

## Scenes

A scene is a layout with its own splits and, optionally, exact window positions.

1. Arrange your windows the way you like them, for example for coding practice.
2. Choose **Scene → New Scene from Current Layout…** and give it a name.
3. When the same set of windows is open again, ⌃⌥L switches to that scene automatically.

Matching only looks at main and reference windows, so whether music or chat is open doesn't matter. A scene is picked when it overlaps the open windows by more than half; otherwise the default scene is used.

## Identify a window by title

To remember one browser window separately (for example the one with your problem set), focus it and choose **"Chrome" Role → Identify Current Window by Title…**, then enter a keyword from its title.

## Rules file

Choose **Edit Rules File…** from the menu, then **Reload Rules** after saving.

```jsonc
{
  "appRoles": { "com.microsoft.VSCode": "main", "com.google.Chrome": "reference" },
  "titleRules": [
    { "contains": "LeetCode", "role": "reference", "appRole": "reference" },     // all browsers
    { "contains": "CS 225", "role": "reference", "bundleID": "com.google.Chrome" } // Chrome only
  ],
  "gap": 8,                        // gap between windows (pt)
  "singleScreenMainRatio": 0.6,    // default code-area width on a single screen
  "mainScreenIndex": 1             // force the main screen (0 = leftmost); remove for automatic
}
```

To find an app's bundle ID, run `osascript -e 'id of app "Visual Studio Code"'`.

## Localization

User-facing strings live in `Resources/<language>.lproj/Localizable.strings`, with the English text as the key. `build.sh` copies them into the app bundle. macOS picks the language from your system settings, including the per-app setting in **System Settings → General → Language & Region → Applications**.

To add a language:

1. Copy `Resources/en.lproj` to `Resources/<code>.lproj` (for example `ja.lproj`) and translate the values.
2. Add the language code to `CFBundleLocalizations` in `Resources/Info.plist`.

## Project layout

```
Sources/SmartTile/
├── main.swift            Entry point (menu bar app, no Dock icon)
├── AppDelegate.swift     Menu, hotkeys, scenes menu, launch at login, stats window
├── Controller.swift      Window events, arranging and undo, learning, scenes, switcher
├── WindowEvents.swift    AXObserver: window created / moved / resized / focused
├── LayoutEngine.swift    Layout algorithm (pure): area splits, dividers, scene positions
├── Store.swift           config / habits / scenes persistence and learning logic
├── Accessibility.swift   Accessibility API wrapper, coordinate conversion
├── HotKeys.swift         Carbon global hotkeys, closure-based menu items
├── Models.swift          Roles, rules, scenes and the default rules
├── L10n.swift            Localization helper
└── StatsView.swift       SwiftUI "Habits & Learning" window
Resources/
├── Info.plist
├── AppIcon.icns / AppIcon.png   App icon (generated by scripts/generate_icon.py)
├── en.lproj/Localizable.strings
└── zh-Hans.lproj/Localizable.strings
Tests/SmartTileTests/
└── LayoutEngineTests.swift
scripts/
└── generate_icon.py       Draws the app icon (pip3 install pillow numpy)
.github/workflows/ci.yml   Runs the tests and packages the app on every push
```

## Continuous integration

Every push and pull request runs the unit tests on GitHub Actions and builds an ad-hoc signed `SmartTile.app`, which you can download from the run's **Artifacts**. An ad-hoc signed build from someone else's machine is blocked by Gatekeeper on first launch. To open it, right-click the app and choose **Open**, or build it yourself.

## Known limitations

- Only windows on the **current Space** are managed. macOS has no public API for moving windows between Spaces.
- Full-screen windows, minimized windows and fixed-size windows (such as System Settings) are ignored.
- Some apps enforce a minimum size and may end up slightly larger than their slot.
- Scene positions are exact, so they have no draggable dividers. To change one, rearrange the windows and press ⌃⌥S.

## License

[MIT](LICENSE)
