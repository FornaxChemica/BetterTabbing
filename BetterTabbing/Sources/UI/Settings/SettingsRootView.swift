import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case features
    case general
    case shortcuts
    case excludedApps
    case windowSlots
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .features: return "Features"
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .excludedApps: return "Excluded Apps"
        case .windowSlots: return "Window Slots"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .features: return "slider.horizontal.3"
        case .general: return "gear"
        case .shortcuts: return "keyboard"
        case .excludedApps: return "eye.slash"
        case .windowSlots: return "number.square"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var selectedTab: SettingsTab = .features
}

/// Light frosted settings backdrop — blur visible in chrome gaps; grouped cards stay readable.
private struct SettingsFrostedBackground: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.thinMaterial)

            Color.black.opacity(0.09)
        }
        .ignoresSafeArea()
    }
}

struct SettingsRootView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var navigation = SettingsNavigation.shared

    var body: some View {
        ZStack {
            SettingsFrostedBackground()

            NavigationSplitView {
                List(selection: $navigation.selectedTab) {
                    ForEach(SettingsTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.systemImage)
                            .tag(tab)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 240)
            } detail: {
                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .toolbarTitleDisplayMode(.inline)
                    .scrollContentBackground(.hidden)
            }
            .navigationSplitViewStyle(.balanced)
            .background(Color.clear)
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(SettingsWindowConfiguratorView())
        .environmentObject(appState)
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            navigation.selectedTab = .features
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch navigation.selectedTab {
        case .features:
            FeaturesSettingsView()
        case .general:
            GeneralSettingsView()
        case .shortcuts:
            ShortcutSettingsView()
        case .excludedApps:
            ExcludedAppsSettingsView()
        case .windowSlots:
            WindowSlotsSettingsView()
        case .about:
            AboutView()
        }
    }
}
