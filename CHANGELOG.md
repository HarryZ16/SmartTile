# Changelog

## 0.1.0 (2026-10)

First public release.

- Role-based tiling for 1, 2 and 3+ displays (main / reference / aux areas).
- Learns split ratios when you drag the edge between two windows; neighbors move out of the way.
- Learns a window's role when you drag it into another area twice.
- Learns the main screen from where you drag code windows and where you code most.
- Scenes: save layouts and switch automatically based on the open windows.
- Identify individual windows by title keyword.
- Undo (⌃⌥Z), window switcher (⌃⌥Space), area focus hotkeys (⌃⌥1/2/3).
- Event-driven window tracking via AXObserver.
- Launch at login.
- English and Simplified Chinese, following the system language.
- Unit tests for the layout engine; CI on GitHub Actions.
