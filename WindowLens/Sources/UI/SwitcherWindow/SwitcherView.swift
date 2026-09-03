import AppKit
import Carbon.HIToolbox
import SwiftUI

struct SwitcherView: View {
    @EnvironmentObject var appState: AppState
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
        let contentWidth = currentAppOverlayContentWidth

        return VStack(spacing: 12) {
            if showSearchResults {
                workspaceSearchResultsStage
            } else if appState.isResourceMonitorActive {
                resourceMonitorInlinePanel
            } else if appState.isUnusedWindowsActive {
                UnusedWindowsInlineView()
            } else {
                workspaceAppSwitcherHeader

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

            workspaceSearchSurface

            workspaceCommandStrip
        }
        .frame(width: contentWidth)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private var resourceMonitorInlinePanel: some View {
        NativeLiquidGlassSurface(
            cornerRadius: 16,
            tintOpacity: 0.03,
            strokeOpacity: 0.06,
            shadowOpacity: 0.08,
            shadowRadius: 14,
            shadowYOffset: 6
        ) {
            ResourceMonitorView(
                entries: appState.resourceEntries,
                systemMemory: appState.systemMemory,
                systemCPU: appState.systemCPU,
                cpuTemperature: appState.cpuTemperature,
                thermalState: appState.thermalState,
                cpuHistory: appState.cpuHistory,
                memoryHistory: appState.memoryHistory,
                aiInsight: appState.aiInsight,
                aiInsightLoading: appState.aiInsightLoading,
                ollamaAvailable: appState.ollamaAvailable,
                isEHoldActive: appState.isEHoldActive,
                eHoldProgress: appState.eHoldProgress,
                isGroupingEnabled: appState.isProcessGroupingEnabled,
                onRefreshInsight: { appState.refreshAIInsight() }
            )
            .padding(12)
        }
    }

    private var currentAppOverlayContentWidth: CGFloat {
        if appState.isResourceMonitorActive {
            return 680
        }
        if appState.isUnusedWindowsActive {
            return 640
        }

        let windowCount = appState.selectedApp.map(realWindowCount(for:)) ?? 1
        return nativePreviewWidth(for: max(windowCount, 1))
    }

    private func realWindowCount(for app: ApplicationModel) -> Int {
        let realWindows = app.windows.filter { !$0.isWindowlessPlaceholder }.count
        return realWindows > 0 ? realWindows : app.windows.count
    }

    private var globalWindowSearchOverlay: some View {
        VStack(spacing: 14) {
            SearchBarView(
                searchQuery: $appState.searchQuery,
                isFocused: $isSearchFocused,
                chromeStyle: .embedded,
                onSubmit: {
                    confirmSelection()
                }
            )

            workspaceSearchResultsStage
                .frame(maxWidth: calculateWidth() - 36)

            workspaceCommandStrip
        }
        .padding(18)
        .background {
            FrostedPanelBackground(
                cornerRadius: 22,
                shadowOpacity: 0.18,
                shadowRadius: 22,
                shadowYOffset: 10
            )
        }
        .padding(.vertical, 10)
    }

    private var selectedPreviewWindowIndex: Int {
        appState.selectedSearchResult?.targetWindowIndex ?? appState.selectedWindowIndex
    }

    private var workspaceSearchResultsStage: some View {
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
            .frame(width: 300)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.05))
            }

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
                .background {
                    FrostedPanelBackground(cornerRadius: 14, shadowOpacity: 0.10, shadowRadius: 10, shadowYOffset: 5)
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var workspaceCommandStrip: some View {
        if isPinnedWindowSearch || showSearchResults {
            globalSearchCommandStrip
        } else {
            carouselCommandStrip
        }
    }

    private var carouselCommandStrip: some View {
        let shortcuts = appState.preferences.shortcuts
        let modules = appState.preferences.modules

        return HStack(spacing: 10) {
            commandHint(keys: workspaceCycleKeySymbols(from: shortcuts.workspaceOpen), label: "next app")
            commandHint(keys: ["U"], label: "unused", isActive: appState.isUnusedWindowsActive)
            if modules.usageHeatmapEnabled {
                commandHint(keys: ["H"], label: "open heatmap")
            }
            commandHint(keys: ["return"], label: "search")
            commandHint(keys: ["esc"], label: "close")
        }
        .fixedSize(horizontal: true, vertical: false)
        .commandStripChrome()
        .frame(maxWidth: .infinity)
    }

    private var globalSearchCommandStrip: some View {
        let canCycleWindows = (appState.selectedApp?.windows.filter { !$0.isWindowlessPlaceholder }.count ?? 0) > 1

        return HStack(spacing: 14) {
            commandHint(keys: ["up", "down"], label: "select")
            if canCycleWindows {
                commandHint(keys: ["tab"], label: "window")
            }
            commandHint(keys: ["return"], label: "open")
            commandHint(keys: ["esc"], label: "clear / dismiss")
        }
        .fixedSize(horizontal: true, vertical: false)
        .commandStripChrome()
        .frame(maxWidth: .infinity)
    }

    private func commandHint(
        keys: [String],
        label: String,
        isEnabled: Bool = true,
        isActive: Bool = false
    ) -> some View {
        KeyHint(keys: keys, label: label, isActive: isActive)
            .opacity(isEnabled ? 1 : 0.4)
    }

    private func workspaceCycleKeySymbols(from binding: KeyboardShortcutBinding) -> [String] {
        WorkspaceCommandStripSymbols.cycleKeySymbols(from: binding)
    }

    @ViewBuilder
    private var workspaceAppSwitcherHeader: some View {
        if appState.selectedApp != nil {
            VStack(spacing: 8) {
                CurrentAppHeader()
                    .id(workspaceWindowCarouselIdentity)

                if appState.filteredApplications.count > 1 {
                    workspaceAppSwitcherRail
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Forces header/panel refresh when the live window list changes (`ApplicationModel` equality is pid-only).
    private var workspaceWindowCarouselIdentity: String {
        guard let app = appState.selectedApp else { return "none" }
        return app.windows.map(\.carouselItemID).joined(separator: "|")
    }

    private var workspaceAppSwitcherRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(appState.filteredApplications.enumerated()), id: \.element.id) { index, app in
                    let isSelected = index == appState.selectedAppIndex

                    AppRailToken(
                        app: app,
                        isSelected: isSelected,
                        isQuitHoldActive: appState.isQuitHoldActive && index == appState.quitTargetAppIndex,
                        quitHoldProgress: isSelected ? appState.quitHoldProgress : 0
                    )
                    .onTapGesture {
                        appState.selectedAppIndex = index
                        appState.selectedWindowIndex = 0
                        appState.refreshWorkspaceWindowsForSelectedApp()
                        confirmSelection()
                    }
                    .onHover { hovering in
                        guard hovering, appState.shouldProcessMouseInput else { return }
                        appState.selectedAppIndex = index
                        appState.selectedWindowIndex = 0
                        appState.refreshWorkspaceWindowsForSelectedApp()
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .fixedSize(horizontal: true, vertical: true)
        .frame(maxWidth: .infinity)
        .onContinuousHover { phase in
            if case .active = phase {
                appState.markMouseNavigation(at: NSEvent.mouseLocation)
            }
        }
    }

    /// Calculate optimal width based on number of apps
    private func calculateWidth() -> CGFloat {
        let appCount = appState.filteredApplications.count

        if appState.presentationMode == .nativePreview {
            return nativePreviewWidth(for: appState.selectedApp?.openWindowCount ?? 1)
        }

        if isPinnedWindowSearch {
            return 1040
        }

        if appState.workspaceMode == .currentAppWindows {
            if appState.isResourceMonitorActive {
                return 680
            }
            if appState.isUnusedWindowsActive {
                return 640
            }
            return nativePreviewWidth(for: appState.selectedApp?.openWindowCount ?? 1)
        }

        if showSearchResults {
            return 1040
        }

        if appState.isResourceMonitorActive {
            return 680
        }

        if appState.isUnusedWindowsActive {
            return 640
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

private func windowCountLabel(for app: ApplicationModel) -> String {
    let count = app.windows.filter { !$0.isWindowlessPlaceholder }.count
    return count == 1 ? "1 window" : "\(count) windows"
}

private struct CurrentAppHeader: View {
    @EnvironmentObject private var appState: AppState

    private var app: ApplicationModel? {
        appState.selectedApp
    }

    var body: some View {
        if let app {
            HStack(spacing: 9) {
                Image(nsImage: app.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 24, height: 24)
                    .cornerRadius(6)

                Text(app.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Text(windowCountLabel(for: app))
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

    var body: some View {
        ZStack {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: isSelected ? 28 : 24, height: isSelected ? 28 : 24)
                .shadow(color: .black.opacity(0.16), radius: 2, x: 0, y: 1)
                .opacity(isQuitHoldActive ? 0.55 : 1)

            if isQuitHoldActive {
                CircularProgressRing(
                    progress: quitHoldProgress,
                    color: .red,
                    lineWidth: 2,
                    size: 36
                )
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(isSelected ? 0.10 : 0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(isSelected ? 0.14 : 0.05), lineWidth: 0.5)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.easeInOut(duration: 0.16), value: isSelected)
    }
}

/// A polished macOS-style keyboard key cap
struct KeyCap: View {
    let symbol: String
    var isActive: Bool = false

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
        .foregroundStyle(.primary.opacity(isActive ? 0.85 : 0.6))
        .frame(minWidth: 18, minHeight: 16)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(isActive ? 0.15 : 0.1))
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
    var isActive: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) {
                ForEach(keys, id: \.self) { key in
                    KeyCap(symbol: key, isActive: isActive)
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct UnusedWindowsInlineView: View {
    var body: some View {
        NativeLiquidGlassSurface(
            cornerRadius: 16,
            tintOpacity: 0.03,
            strokeOpacity: 0.06,
            shadowOpacity: 0.08,
            shadowRadius: 14,
            shadowYOffset: 6
        ) {
            DeadWindowsView(isInline: true)
                .frame(maxWidth: .infinity, maxHeight: 420)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

enum WorkspaceCommandStripSymbols {
    /// Key caps shown while the workspace modifier is held — omits the open-workspace modifier.
    static func cycleKeySymbols(from binding: KeyboardShortcutBinding) -> [String] {
        keySymbols(for: KeyboardShortcutBinding(keyCode: binding.keyCode, modifiers: []))
    }

    static func keySymbols(for binding: KeyboardShortcutBinding) -> [String] {
        var keys: [String] = []
        for modifier in ModifierKey.allCases where binding.modifiers.contains(modifier) {
            switch modifier {
            case .command:
                keys.append("cmd")
            case .shift:
                keys.append("shift")
            case .option:
                keys.append("opt")
            case .control:
                keys.append("ctrl")
            }
        }

        keys.append(keySymbol(for: binding.keyCode))
        return keys
    }

    static func keySymbol(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Tab:
            return "tab"
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return "return"
        case kVK_Escape:
            return "esc"
        case kVK_ANSI_Grave:
            return "`"
        case kVK_ANSI_E:
            return "E"
        case kVK_ANSI_Q:
            return "Q"
        case kVK_ANSI_W:
            return "W"
        case kVK_UpArrow:
            return "up"
        case kVK_DownArrow:
            return "down"
        case kVK_ANSI_1:
            return "1"
        case kVK_ANSI_2:
            return "2"
        default:
            return KeyboardShortcutBinding.keyDisplayName(for: keyCode).lowercased()
        }
    }
}

private extension View {
    func commandStripChrome() -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                FrostedPanelBackground(
                    cornerRadius: 13,
                    shadowOpacity: 0.10,
                    shadowRadius: 10,
                    shadowYOffset: 5
                )
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
    static let workspaceSearchKeyboardCaptureEnabled = Notification.Name("workspaceSearchKeyboardCaptureEnabled")
    static let workspaceWindowActivated = Notification.Name("workspaceWindowActivated")
    static let reinstallEventTap = Notification.Name("reinstallEventTap")
    static let openPermissions = Notification.Name("openPermissions")
    static let openHeatmap = Notification.Name("openHeatmap")
    static let openDeadWindows = Notification.Name("openDeadWindows")
}
