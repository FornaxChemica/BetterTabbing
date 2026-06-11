import SwiftUI

struct SearchBarView: View {
    enum ChromeStyle {
        /// Standalone frosted card (matches Settings panels).
        case frostedCard
        /// Content only — parent supplies the frosted shell.
        case embedded
    }

    @EnvironmentObject private var appState: AppState
    @Binding var searchQuery: String
    @FocusState.Binding var isFocused: Bool
    var chromeStyle: ChromeStyle = .frostedCard
    var onSubmit: () -> Void

    var body: some View {
        searchFieldContent
            .background {
                if chromeStyle == .frostedCard {
                    FrostedPanelBackground(cornerRadius: 14)
                }
            }
    }

    private var searchFieldContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(searchPlaceholder, text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .id(appState.workspaceSearchScope)
                .onSubmit {
                    onSubmit()
                }
                .onKeyPress(.upArrow) {
                    guard appState.isSearchingWithQuery else { return .ignored }
                    appState.selectPreviousApp()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard appState.isSearchingWithQuery else { return .ignored }
                    appState.selectNextApp()
                    return .handled
                }
                .onKeyPress(.leftArrow) {
                    guard appState.isSearchingWithQuery else { return .ignored }
                    appState.selectPreviousApp()
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    guard appState.isSearchingWithQuery else { return .ignored }
                    appState.selectNextApp()
                    return .handled
                }
                .onKeyPress(keys: [.tab], phases: .down) { press in
                    guard appState.isSearchingWithQuery else { return .ignored }
                    if press.modifiers.contains(.shift) {
                        appState.selectPreviousWindow()
                    } else {
                        appState.selectNextWindow()
                    }
                    return .handled
                }

            Picker("Search scope", selection: searchScopeBinding) {
                Text("This app").tag(WorkspaceSearchScope.currentApp)
                Text("All").tag(WorkspaceSearchScope.allWindows)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .frame(maxWidth: 148)

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var searchScopeBinding: Binding<WorkspaceSearchScope> {
        Binding(
            get: { appState.workspaceSearchScope },
            set: { appState.setWorkspaceSearchScope($0) }
        )
    }

    private var searchPlaceholder: String {
        Self.placeholder(
            scope: appState.workspaceSearchScope,
            appName: appState.currentWorkspaceApp?.name
        )
    }

    static func placeholder(scope: WorkspaceSearchScope, appName: String?) -> String {
        switch scope {
        case .currentApp:
            let resolvedName = appName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = (resolvedName?.isEmpty == false) ? resolvedName! : "this app"
            return "Search \(label) windows…"
        case .allWindows:
            return "Search all windows…"
        }
    }
}
