import SwiftUI

struct AppStat: Identifiable {
    let id: String
    let name: String
    let role: String
    let seconds: Double
}

struct RatioStat: Identifiable {
    let id: String
    let label: String
    let value: Double
}

struct RoleStat: Identifiable {
    let id: String
    let name: String
    let role: String
}

struct SceneStat: Identifiable {
    let id: String
    let name: String
    let windows: Int
    let active: Bool
}

struct StatsSnapshot {
    let trusted: Bool
    let screenCount: Int
    let mainScreen: String
    let sceneName: String
    let apps: [AppStat]
    let ratios: [RatioStat]
    let roles: [RoleStat]
    let scenes: [SceneStat]
    let layouts: Int
    let ratioAdjustments: Int
    let rolesLearned: Int
    let dataPath: String
}

/// "Habits & Learning" window: shows what SmartTile has learned.
/// All strings are localized with L() before being handed to Text(verbatim:).
struct StatsView: View {
    let s: StatsSnapshot

    private var maxSeconds: Double {
        max(s.apps.map { $0.seconds }.max() ?? 1, 1)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: L("SmartTile Habits")).font(.title2).bold()

                HStack(spacing: 24) {
                    stat(L("Accessibility"), s.trusted ? L("Granted") : L("Not granted"))
                    stat(L("Screens"), "\(s.screenCount)")
                    stat(L("Main screen"), s.mainScreen)
                    stat(L("Current scene"), s.sceneName)
                }
                HStack(spacing: 24) {
                    stat(L("Arrangements"), "\(s.layouts)")
                    stat(L("Split adjustments"), "\(s.ratioAdjustments)")
                    stat(L("Learned roles"), "\(s.rolesLearned)")
                }

                section(L("Scenes (%d screens)", s.screenCount)) {
                    ForEach(s.scenes) { sc in
                        HStack {
                            Image(systemName: sc.active ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(sc.active ? .accentColor : .secondary)
                            Text(verbatim: sc.name)
                            Spacer()
                            Text(verbatim: sc.windows > 0 ? L("%d window positions saved", sc.windows) : L("Template layout"))
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }

                section(L("Splits in the current scene")) {
                    if s.ratios.isEmpty {
                        hint(L("Default splits. Drag the edge between two windows and the new split is remembered; neighboring windows move out of the way."))
                    }
                    ForEach(s.ratios) { r in
                        HStack {
                            Text(verbatim: r.label)
                            Spacer()
                            let pct = Int((r.value * 100).rounded())
                            Text(verbatim: "\(pct)% : \(100 - pct)%").monospacedDigit()
                        }
                    }
                }

                section(L("Learned window roles")) {
                    if s.roles.isEmpty {
                        hint(L("Drag a window into another area twice in a row (e.g. a chat app into the reference area) and it will be remembered."))
                    }
                    ForEach(s.roles) { r in
                        HStack {
                            Text(verbatim: r.name).lineLimit(1)
                            Spacer()
                            Text(verbatim: L("Goes to the %@ area", r.role)).foregroundColor(.secondary)
                        }
                    }
                }

                section(L("Foreground time per app")) {
                    if s.apps.isEmpty {
                        hint(L("No data yet. Use your Mac for a while and check back."))
                    }
                    ForEach(s.apps) { a in
                        HStack(spacing: 8) {
                            Text(verbatim: a.name).lineLimit(1).frame(width: 150, alignment: .leading)
                            Text(verbatim: a.role).foregroundColor(.secondary).frame(width: 64, alignment: .leading)
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.accentColor.opacity(0.75))
                                    .frame(width: max(2, geo.size.width * CGFloat(a.seconds / maxSeconds)))
                            }
                            .frame(height: 10)
                            Text(verbatim: Self.format(a.seconds)).monospacedDigit()
                                .frame(width: 72, alignment: .trailing)
                        }
                    }
                }

                Text(verbatim: L("Data folder: %@", s.dataPath))
                    .font(.caption).foregroundColor(.secondary).textSelection(.enabled)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 580, minHeight: 560)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(verbatim: title)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(verbatim: text).font(.callout).foregroundColor(.secondary)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title).font(.caption).foregroundColor(.secondary)
            Text(verbatim: value).font(.headline)
        }
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s >= 3600 { return L("%dh %02dm", s / 3600, (s % 3600) / 60) }
        if s >= 60 { return L("%dm", s / 60) }
        return L("%ds", s)
    }
}
