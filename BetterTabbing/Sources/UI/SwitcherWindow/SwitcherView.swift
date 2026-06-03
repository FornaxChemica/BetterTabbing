import AppKit
import SwiftUI

struct SwitcherView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var slotRegistry = WindowNumberRegistry.shared
    @FocusState private var isSearchFocused: Bool

    /// Whether to show search results list (when searching with query)
    private var showSearchResults: Bool {
        appState.isSearchActive && !appState.searchQuery.isEmpty
    }

    private var isPinnedWindowSearch: Bool {
        appState.presentationMode == .workspace && appState.workspaceMode == .globalWindowSearch
    }

    var body: some View {
        Group {
            if appState.presentationMode == .nativePreview {
                nativePreviewOverlay
            } else if isPinnedWindowSearch {
                globalWindowSearchOverlay
            } else {
                currentAppWindowOverlay
            }
        }
        .frame(width: calculateWidth())
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeInOut(duration: 0.18), value: appState.presentationMode)
        .animation(.easeInOut(duration: 0.18), value: appState.selectedAppIndex)
        .animation(.easeInOut(duration: 0.16), value: appState.selectedWindowIndex)
        .onChange(of: appState.isSearchActive) { oldValue, isActive in
            if isActive {
                appState.selectedSearchIndex = 0
                // Delay focus to next run loop so the SearchBarView is fully
                // inserted into the hierarchy and the panel resize has started
                DispatchQueue.main.async {
                    isSearchFocused = true
                }
            }
        }
        .onChange(of: appState.searchQuery) { oldValue, newValue in
            appState.selectedSearchIndex = 0
        }
    }

    private var nativePreviewOverlay: some View {
        VStack(spacing: 12) {
            if let selectedApp = appState.selectedApp {
                WindowListView(
                    app: selectedApp,
                    selectedWindowIndex: appState.selectedWindowIndex,
                    presentationMode: .nativePreview,
                    onWindowHovered: { _ in },
                    onWindowClicked: { _ in }
                )
            }
        }
        .padding(.vertical, 10)
    }

    private var currentAppWindowOverlay: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer(minLength: 0)
                appRail
                Spacer(minLength: 0)
            }

            if let selectedApp = appState.selectedApp {
                WindowListView(
                    app: selectedApp,
                    selectedWindowIndex: appState.selectedWindowIndex,
                    presentationMode: .workspace,
                    onWindowHovered: { index in
                        guard appState.shouldProcessMouseInput else { return }
                        appState.selectedWindowIndex = index
                    },
                    onWindowClicked: { index in
                        appState.selectedWindowIndex = index
                        confirmSelection()
                    }
                )
                .onContinuousHover { phase in
                    if case .active = phase {
                        appState.markMouseNavigation(at: NSEvent.mouseLocation)
                    }
                }
            }
        }
        .padding(.vertical, 10)
    }

    private var globalWindowSearchOverlay: some View {
        VStack(spacing: 12) {
            SearchBarView(
                searchQuery: $appState.searchQuery,
                isFocused: $isSearchFocused,
                onSubmit: {
                    confirmSelection()
                }
            )
            .frame(width: min(calculateWidth() - 220, 560))

            HStack(alignment: .top, spacing: 16) {
                SearchResultsListView(
                    results: appState.searchResults,
                    selectedIndex: appState.selectedSearchIndex,
                    onResultClicked: { index in
                        appState.selectedSearchIndex = index
                        if let result = appState.selectedSearchResult,
                           let windowIndex = result.targetWindowIndex {
                            appState.selectedWindowIndex = windowIndex
                        }
                        confirmSelection()
                    }
                )
                .padding(14)
                .frame(width: 330)
                .background(
                    GlassBackground(
                        cornerRadius: 18,
                        tintOpacity: 0.045,
                        strokeOpacity: 0.08,
                        shadowOpacity: 0.08,
                        shadowRadius: 14,
                        shadowYOffset: 8
                    )
                )

                if let selectedApp = appState.selectedApp {
                    WindowListView(
                        app: selectedApp,
                        selectedWindowIndex: selectedPreviewWindowIndex,
                        presentationMode: .workspace,
                        onWindowHovered: { index in
                            guard appState.shouldProcessMouseInput else { return }
                            appState.selectedWindowIndex = index
                        },
                        onWindowClicked: { index in
                            appState.selectedWindowIndex = index
                            confirmSelection()
                        }
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: calculateWidth())
        }
        .padding(.vertical, 10)
    }

    private var selectedPreviewWindowIndex: Int {
        appState.selectedSearchResult?.targetWindowIndex ?? appState.selectedWindowIndex
    }

    @ViewBuilder
    private var workspaceSearchSurface: some View {
        if appState.isSearchActive {
            SearchBarView(
                searchQuery: $appState.searchQuery,
                isFocused: $isSearchFocused,
                onSubmit: {
                    confirmSelection()
                }
            )
            .frame(width: min(calculateWidth() - 220, 560))
            .transition(.move(edge: .top).combined(with: .opacity))
        } else {
            Button {
                NotificationCenter.default.post(name: .activateSwitcherSearch, object: nil)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text("Search apps and windows")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    KeyCap(symbol: "return")
                        .opacity(0.72)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(width: min(calculateWidth() - 260, 440))
                .background(
                    GlassBackground(
                        cornerRadius: 14,
                        tintOpacity: 0.03,
                        strokeOpacity: 0.055,
                        shadowOpacity: 0.05,
                        shadowRadius: 9,
                        shadowYOffset: 4
                    )
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var workspaceCommandStrip: some View {
        HStack(spacing: 14) {
            KeyHint(keys: ["tab"], label: showSearchResults ? "Result" : "App")
            KeyHint(keys: ["`"], label: "Window")
            KeyHint(keys: ["return"], label: appState.isSearchActive ? "Open" : "Search")
            KeyHint(keys: ["E"], label: "Monitor")
            KeyHint(keys: ["Q"], label: "Hold quit")
            KeyHint(keys: ["esc"], label: "Close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            GlassBackground(
                cornerRadius: 13,
                tintOpacity: 0.026,
                strokeOpacity: 0.045,
                shadowOpacity: 0.035,
                shadowRadius: 8,
                shadowYOffset: 4
            )
        )
        .opacity(0.84)
    }

    private var appRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(Array(appState.filteredApplications.enumerated()), id: \.element.id) { index, app in
                    let isSelected = index == appState.selectedAppIndex
                    let slotNumbers = slotRegistry.slotNumbers(for: app.pid)

                    AppRailToken(
                        app: app,
                        isSelected: isSelected,
                        isQuitHoldActive: appState.isQuitHoldActive && index == appState.quitTargetAppIndex,
                        quitHoldProgress: isSelected ? appState.quitHoldProgress : 0,
                        windowSlotNumbers: slotNumbers
                    )
                    .onTapGesture {
                        appState.selectedAppIndex = index
                        appState.selectedWindowIndex = 0
                        confirmSelection()
                    }
                    .onHover { hovering in
                        guard hovering, appState.shouldProcessMouseInput else { return }
                        appState.selectedAppIndex = index
                        appState.selectedWindowIndex = 0
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                GlassBackground(
                    cornerRadius: 18,
                    tintOpacity: 0.035,
                    strokeOpacity: 0.06,
                    shadowOpacity: 0.06,
                    shadowRadius: 12,
                    shadowYOffset: 6
                )
            )
        }
        .frame(width: appRailWidth())
        .onContinuousHover { phase in
            if case .active = phase {
                appState.markMouseNavigation(at: NSEvent.mouseLocation)
            }
        }
    }

    private func appRailWidth() -> CGFloat {
        let appCount = max(appState.filteredApplications.count, 1)
        let estimatedChipWidth = CGFloat(min(appCount, 10)) * 52

        return min(max(estimatedChipWidth + 28, 160), 760)
    }

    /// Calculate optimal width based on number of apps
    private func calculateWidth() -> CGFloat {
        let appCount = appState.filteredApplications.count

        if appState.presentationMode == .nativePreview {
            return nativePreviewWidth(for: appState.selectedApp?.windows.count ?? 1)
        }

        if isPinnedWindowSearch {
            return 1040
        }

        if appState.workspaceMode == .currentAppWindows {
            let windowCount = appState.selectedApp?.windows.count ?? 1
            let appCount = appState.filteredApplications.count
            let railWidth = CGFloat(min(appCount, 10)) * 58 + 120
            return max(nativePreviewWidth(for: windowCount), min(max(railWidth, 780), 1040))
        }

        if showSearchResults {
            return 1040
        }

        if appState.isResourceMonitorActive {
            return 680
        }

        if appState.isSearchActive && appState.searchQuery.isEmpty {
            // Search mode but no query yet - use app grid width
            let idealItemsPerRow = min(appCount, 10)
            let baseWidth = CGFloat(idealItemsPerRow) * 58 + 120
            return min(max(baseWidth, 780), 1040)
        }

        // Calculate based on app count
        let idealItemsPerRow = min(appCount, 10)
        let baseWidth = CGFloat(idealItemsPerRow) * 58 + 120

        return min(max(baseWidth, 780), 1040)
    }

    private func nativePreviewWidth(for windowCount: Int) -> CGFloat {
        let screenWidth = NSScreen.main?.visibleFrame.width ?? 1440
        let maximumWidth = min(screenWidth * 0.92, 1320)

        let idealWidth: CGFloat
        switch windowCount {
        case 0...1:
            idealWidth = 620
        case 2:
            idealWidth = 900
        case 3:
            idealWidth = 1180
        default:
            idealWidth = 1240
        }

        let minimumWidth = min(620, maximumWidth)
        return max(minimumWidth, min(idealWidth, maximumWidth))
    }

    private func confirmSelection() {
        NotificationCenter.default.post(name: .confirmSwitcherSelection, object: nil)
    }
}

private struct CurrentAppHeader: View {
    let app: ApplicationModel

    var body: some View {
        HStack(spacing: 9) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
                .cornerRadius(6)

            Text(app.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            Text("\(app.windows.filter { !$0.isWindowlessPlaceholder }.count) windows")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(
            GlassBackground(
                cornerRadius: 14,
                tintOpacity: 0.03,
                strokeOpacity: 0.055,
                shadowOpacity: 0.055,
                shadowRadius: 10,
                shadowYOffset: 5
            )
        )
    }
}

private struct WorkspaceContextStrip: View {
    let app: ApplicationModel

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
                .cornerRadius(5)

            Text(app.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)

            if let title = app.primaryWindowTitle {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: 460)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            GlassBackground(
                cornerRadius: 14,
                tintOpacity: 0.03,
                strokeOpacity: 0.05,
                shadowOpacity: 0.05,
                shadowRadius: 9,
                shadowYOffset: 4
            )
        )
    }
}

private struct AppRailToken: View {
    let app: ApplicationModel
    let isSelected: Bool
    let isQuitHoldActive: Bool
    let quitHoldProgress: CGFloat
    let windowSlotNumbers: [Int]

    var body: some View {
        HStack(spacing: isSelected ? 8 : 0) {
            ZStack {
                Image(nsImage: app.icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 30, height: 30)
                    .shadow(color: .black.opacity(0.16), radius: 2, x: 0, y: 1)
                    .opacity(isQuitHoldActive ? 0.55 : 1)

                if isQuitHoldActive {
                    CircularProgressRing(
                        progress: quitHoldProgress,
                        color: .red,
                        lineWidth: 2,
                        size: 40
                    )
                }

                if let badgeLabel = WindowSlotBadge.railLabel(for: windowSlotNumbers) {
                    WindowSlotBadge(label: badgeLabel)
                        .offset(x: 12, y: -12)
                }
            }

            if isSelected {
                Text(app.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .padding(.horizontal, isSelected ? 10 : 7)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(Color.white.opacity(isSelected ? 0.09 : 0.015))
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(isSelected ? 0.10 : 0.03), lineWidth: 0.5)
                )
        )
        .contentShape(Capsule())
        .animation(.easeInOut(duration: 0.16), value: isSelected)
    }
}

/// A polished macOS-style keyboard key cap
struct KeyCap: View {
    let symbol: String

    /// Maps key names to SF Symbols or display text
    private var displayContent: (isSymbol: Bool, value: String) {
        switch symbol.lowercased() {
        case "tab":
            return (true, "arrow.right.to.line")
        case "return", "enter":
            return (true, "return")
        case "esc", "escape":
            return (false, "esc")
        case "shift":
            return (true, "shift")
        case "cmd", "command":
            return (true, "command")
        case "opt", "option", "alt":
            return (true, "option")
        case "ctrl", "control":
            return (true, "control")
        case "up":
            return (true, "chevron.up")
        case "down":
            return (true, "chevron.down")
        case "left":
            return (true, "chevron.left")
        case "right":
            return (true, "chevron.right")
        case "space":
            return (false, "space")
        case "`":
            return (false, "`")
        default:
            return (false, symbol.uppercased())
        }
    }

    var body: some View {
        let content = displayContent

        Group {
            if content.isSymbol {
                Image(systemName: content.value)
                    .font(.system(size: 9, weight: .medium))
            } else {
                Text(content.value)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(.primary.opacity(0.6))
        .frame(minWidth: 18, minHeight: 16)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                )
        )
    }
}

/// A keyboard hint showing key(s) + description
struct KeyHint: View {
    let keys: [String]
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) {
                ForEach(keys, id: \.self) { key in
                    KeyCap(symbol: key)
                }
            }

            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

extension Notification.Name {
    static let confirmSwitcherSelection = Notification.Name("confirmSwitcherSelection")
    static let switcherDismissedByClickOutside = Notification.Name("switcherDismissedByClickOutside")
    static let switcherConfirmedByMouseClick = Notification.Name("switcherConfirmedByMouseClick")
    static let activationModifierChanged = Notification.Name("activationModifierChanged")
    static let openSettings = Notification.Name("openSettings")
    static let shortcutsDidChange = Notification.Name("shortcutsDidChange")
    static let activateSwitcherSearch = Notification.Name("activateSwitcherSearch")
    static let workspaceWindowActivated = Notification.Name("workspaceWindowActivated")
    static let reinstallEventTap = Notification.Name("reinstallEventTap")
    static let openPermissions = Notification.Name("openPermissions")
}
