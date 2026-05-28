import AppKit
import Carbon.HIToolbox
import SwiftUI
import Combine
import QuartzCore

final class SwitcherPanel: NSPanel {
    private var hostingView: NSHostingView<AnyView>?
    private var cancellables = Set<AnyCancellable>()
    private var clickOutsideMonitor: Any?
    private let entranceDuration: TimeInterval = 0.12
    private let dismissalDuration: TimeInterval = 0.08
    private var presentationMode: SwitcherPresentationMode = .workspace

    /// The Y position of the top of the app grid (used to anchor expansions)
    private var gridTopY: CGFloat = 0

    /// The screen this panel is associated with (for multi-screen support)
    private(set) var associatedScreen: NSScreen?

    init(screen: NSScreen? = nil) {
        self.associatedScreen = screen
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configure()
        setupHostingView()
        setupNotifications()
        setupStateObservers()
    }

    /// Update the associated screen (used when screen configuration changes)
    func updateAssociatedScreen(_ screen: NSScreen) {
        self.associatedScreen = screen
    }

    private func configure() {
        // Workspace mode is a keyboard-owned surface; Cmd+Tab augmentation is raised when shown.
        level = .statusBar

        // Appearance
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        // Behavior
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false

        // Appear on all spaces
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient
        ]

        animationBehavior = .none
    }

    // Allow the panel to become key window (needed for TextField input)
    override var canBecomeKey: Bool { true }

    private func setupHostingView() {
        let switcherView = SwitcherView()
            .environmentObject(AppState.shared)

        hostingView = NSHostingView(rootView: AnyView(switcherView))

        // Critical: Disable Auto Layout constraints for the hosting view
        // This prevents conflicts between NSPanel's frame-based layout and SwiftUI's layout system
        hostingView?.translatesAutoresizingMaskIntoConstraints = true
        hostingView?.autoresizingMask = [.width, .height]
        hostingView?.wantsLayer = true

        contentView = hostingView
    }

    private func setupNotifications() {
        NotificationCenter.default.publisher(for: .confirmSwitcherSelection)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.confirmSelection()
            }
            .store(in: &cancellables)
    }

    private func setupStateObservers() {
        // Observe search state changes to re-center panel
        AppState.shared.$isSearchActive
            .dropFirst()  // Skip initial value
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recenterIfVisible()
            }
            .store(in: &cancellables)

        // Observe search query changes (for search results height)
        AppState.shared.$searchQuery
            .dropFirst()
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recenterIfVisible()
            }
            .store(in: &cancellables)

        // Observe selected app changes (for window list) - resize without animation
        AppState.shared.$selectedAppIndex
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.resizeForWindowList()
            }
            .store(in: &cancellables)

        // Observe resource monitor toggle to re-center panel
        AppState.shared.$isResourceMonitorActive
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recenterIfVisible()
            }
            .store(in: &cancellables)
    }

    // MARK: - Size Calculation (matches SwitcherView)

    private func calculateCurrentSize() -> CGSize {
        let appState = AppState.shared
        let appCount = appState.filteredApplications.count
        let isSearchActive = appState.isSearchActive
        let searchQuery = appState.searchQuery

        if appState.presentationMode == .nativePreview {
            let windowCount = appState.selectedApp?.windows.count ?? 1
            return CGSize(
                width: windowCount > 1 ? 980 : 620,
                height: 362
            )
        }

        // Check if showing search results
        let showSearchResults = isSearchActive && !searchQuery.isEmpty

        // The normal switcher keeps preview geometry reserved even while placeholders are shown.
        let showsPreviewStage = !showSearchResults && !appState.isResourceMonitorActive

        // Width calculation
        let width: CGFloat
        if showSearchResults {
            width = 1040
        } else if appState.isResourceMonitorActive {
            width = 680
        } else {
            let idealItemsPerRow = min(appCount, 10)
            let baseWidth = CGFloat(idealItemsPerRow) * 58 + 92
            width = min(max(baseWidth, 780), 1040)
        }

        // Height calculation
        let searchBarHeight: CGFloat = isSearchActive ? 54 : 0

        let contentHeight: CGFloat
        if showSearchResults {
            let resultCount = min(appState.searchResults.count, 10)
            let resultsHeight = resultCount == 0 ? 80 : CGFloat(resultCount) * 44 + 24
            contentHeight = max(416, resultsHeight + 80)
        } else if appState.isResourceMonitorActive {
            // Resource monitor: bar chart (~100) + header (~20) + entries + hints + padding
            let entryCount = min(appState.resourceEntries.count, 15)
            let chartHeight: CGFloat = 110  // Bar chart area
            let entriesHeight = entryCount == 0 ? 80 : CGFloat(entryCount) * 30 + 24
            let hintsHeight: CGFloat = 30
            contentHeight = chartHeight + entriesHeight + hintsHeight + 14
        } else {
            // Each tile: 58px icon area + label + compact padding.
            let itemsPerRow = max(1, Int((width - 32) / 80))
            let rows = appCount > 0 ? ceil(CGFloat(appCount) / CGFloat(itemsPerRow)) : 1
            let tileHeight: CGFloat = 86
            let gridSpacing: CGFloat = 8
            let gridHeight = rows * tileHeight + (rows - 1) * gridSpacing + 28  // +28 for vertical padding
            let hintsHeight: CGFloat = 30
            let previewStageHeight: CGFloat = showsPreviewStage ? 342 : 0
            contentHeight = gridHeight + hintsHeight + previewStageHeight + 42
        }

        // No extra padding needed - native NSPanel shadow extends beyond frame automatically
        return CGSize(width: width, height: searchBarHeight + contentHeight)
    }

    private func recenterIfVisible() {
        guard isVisible, let screen = associatedScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }

        // Get the intrinsic size from SwiftUI content
        let fittingSize = hostingView?.fittingSize ?? calculateCurrentSize()

        // Apply screen bounds
        let maxWidth: CGFloat = min(screen.frame.width * 0.88, 1040)
        let maxHeight: CGFloat = min(screen.frame.height * 0.85, 800)
        let panelSize = CGSize(
            width: min(fittingSize.width, maxWidth),
            height: min(fittingSize.height, maxHeight)
        )

        // Keep the top of the grid anchored - the panel grows/shrinks from the top
        // When search bar appears, panel grows upward (top goes up)
        // The grid stays at gridTopY
        let origin = CGPoint(
            x: screen.frame.midX - panelSize.width / 2,
            y: gridTopY - panelSize.height  // Anchor to the stored grid top position
        )

        let newFrame = CGRect(origin: origin, size: panelSize)

        // Defer frame change to next run loop iteration to avoid constraint conflicts
        // during the current layout cycle
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isVisible else { return }

            // Animate the frame change for search bar
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().setFrame(newFrame, display: true)
            }
        }
    }

    /// Resize panel for window list without animation - keeps top anchored, grows downward instantly
    private func resizeForWindowList() {
        guard isVisible, let screen = associatedScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }

        // Get the intrinsic size from SwiftUI content
        let fittingSize = hostingView?.fittingSize ?? calculateCurrentSize()

        // Apply screen bounds
        let maxWidth: CGFloat = min(screen.frame.width * 0.88, 1040)
        let maxHeight: CGFloat = min(screen.frame.height * 0.85, 800)
        let panelSize = CGSize(
            width: min(fittingSize.width, maxWidth),
            height: min(fittingSize.height, maxHeight)
        )

        // Keep top anchored - only the bottom changes
        let currentTop = frame.origin.y + frame.size.height
        let origin = CGPoint(
            x: screen.frame.midX - panelSize.width / 2,
            y: currentTop - panelSize.height  // Keep top fixed, grow downward
        )

        // Set frame instantly (no animation) - SwiftUI will animate the content
        setFrame(CGRect(origin: origin, size: panelSize), display: true)
    }

    private func applyWindowLevel(for mode: SwitcherPresentationMode) {
        level = mode == .nativePreview ? .screenSaver : .statusBar
    }

    private func verticalOffset(for mode: SwitcherPresentationMode) -> CGFloat {
        mode == .nativePreview ? 170 : 40
    }

    // MARK: - Public Methods

    /// Show using already-cached data (called after quick-switch timeout)
    /// This is fully synchronous for maximum speed - uses lock-free cache read
    func showWithCachedData(mode: SwitcherPresentationMode = .workspace) {
        presentationMode = mode
        guard let screen = associatedScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }

        let startTime = CFAbsoluteTimeGetCurrent()

        // Use lock-free cached data (prefetch may still be running, that's OK)
        let apps = WindowCache.shared.getCachedApplications()

        // If no cached data yet, do a quick sync fetch (fallback)
        let finalApps = apps.isEmpty ? WindowCache.shared.getApplicationsSync(forceRefresh: true) : apps

        AppState.shared.applications = finalApps
        // Select index 1 (previous app) by default, since index 0 is the current frontmost app
        AppState.shared.selectedAppIndex = finalApps.count > 1 ? 1 : 0
        AppState.shared.selectedWindowIndex = 0
        AppState.shared.prepareForPresentation(mode)
        applyWindowLevel(for: mode)

        // Get the intrinsic size from SwiftUI content
        let fittingSize = hostingView?.fittingSize ?? calculateCurrentSize()

        // Apply screen bounds
        let maxWidth: CGFloat = min(screen.frame.width * 0.88, 1040)
        let maxHeight: CGFloat = min(screen.frame.height * 0.85, 800)
        let panelSize = CGSize(
            width: min(fittingSize.width, maxWidth),
            height: min(fittingSize.height, maxHeight)
        )

        // Center on screen, slightly above center for aesthetic
        let origin = CGPoint(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.frame.midY - panelSize.height / 2 + verticalOffset(for: mode)
        )
        setFrame(CGRect(origin: origin, size: panelSize), display: true)

        // Store the top of the grid as anchor point (top of panel since no search bar initially)
        gridTopY = origin.y + panelSize.height

        presentWithEntranceAnimation()

        // Start monitoring for clicks outside the panel
        startClickOutsideMonitor()

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        print("[SwitcherPanel] Shown in \(Int(elapsed))ms with \(finalApps.count) apps, size: \(Int(panelSize.width))x\(Int(panelSize.height))")
    }

    /// Legacy show method (forces refresh) - synchronous
    func show(mode: SwitcherPresentationMode = .workspace) {
        presentationMode = mode
        guard let screen = associatedScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }

        let apps = WindowCache.shared.getApplicationsSync(forceRefresh: true)
        AppState.shared.applications = apps
        // Select index 1 (previous app) by default, since index 0 is the current frontmost app
        AppState.shared.selectedAppIndex = apps.count > 1 ? 1 : 0
        AppState.shared.selectedWindowIndex = 0
        AppState.shared.prepareForPresentation(mode)
        applyWindowLevel(for: mode)

        // Get the intrinsic size from SwiftUI content
        let fittingSize = hostingView?.fittingSize ?? calculateCurrentSize()

        // Apply screen bounds
        let maxWidth: CGFloat = min(screen.frame.width * 0.88, 1040)
        let maxHeight: CGFloat = min(screen.frame.height * 0.85, 800)
        let panelSize = CGSize(
            width: min(fittingSize.width, maxWidth),
            height: min(fittingSize.height, maxHeight)
        )

        // Center on screen, slightly above center
        let origin = CGPoint(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.frame.midY - panelSize.height / 2 + verticalOffset(for: mode)
        )
        setFrame(CGRect(origin: origin, size: panelSize), display: true)

        // Store the top of the grid as anchor point (top of panel since no search bar initially)
        gridTopY = origin.y + panelSize.height

        presentWithEntranceAnimation()

        // Start monitoring for clicks outside the panel
        startClickOutsideMonitor()
        print("[SwitcherPanel] Shown with size: \(Int(panelSize.width))x\(Int(panelSize.height))")
    }

    /// Show panel on its associated screen (used by SwitcherPanelManager for multi-screen display)
    /// - Parameter skipStateUpdate: If true, assumes AppState is already updated by the manager
    func showOnScreen(mode: SwitcherPresentationMode = .workspace, skipStateUpdate: Bool = false) {
        presentationMode = mode
        applyWindowLevel(for: mode)
        guard let screen = associatedScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }

        if !skipStateUpdate {
            let apps = WindowCache.shared.getCachedApplications()
            let finalApps = apps.isEmpty ? WindowCache.shared.getApplicationsSync(forceRefresh: true) : apps
            AppState.shared.applications = finalApps
            AppState.shared.selectedAppIndex = finalApps.count > 1 ? 1 : 0
            AppState.shared.selectedWindowIndex = 0
            AppState.shared.prepareForPresentation(mode)
        }

        // Get the intrinsic size from SwiftUI content
        let fittingSize = hostingView?.fittingSize ?? calculateCurrentSize()

        // Apply screen bounds
        let maxWidth: CGFloat = min(screen.frame.width * 0.88, 1040)
        let maxHeight: CGFloat = min(screen.frame.height * 0.85, 800)
        let panelSize = CGSize(
            width: min(fittingSize.width, maxWidth),
            height: min(fittingSize.height, maxHeight)
        )

        // Center on screen, slightly above center for spatial preview continuity.
        let origin = CGPoint(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.frame.midY - panelSize.height / 2 + verticalOffset(for: mode)
        )
        setFrame(CGRect(origin: origin, size: panelSize), display: true)

        // Store the top of the grid as anchor point
        gridTopY = origin.y + panelSize.height

        presentWithEntranceAnimation()

        // Start monitoring for clicks outside (posts notification for manager to handle)
        startClickOutsideMonitor()
    }

    /// Recenter on the associated screen (called when screen configuration changes)
    func recenterOnAssociatedScreen() {
        recenterIfVisible()
    }

    /// Hide the panel without resetting AppState (used by manager)
    func hidePanel() {
        stopClickOutsideMonitor()
        dismissWithExitAnimation()
    }

    func hide() {
        // Stop monitoring clicks
        stopClickOutsideMonitor()

        dismissWithExitAnimation()
        AppState.shared.reset()

        print("[SwitcherPanel] Hidden")
    }

    private func presentWithEntranceAnimation() {
        hostingView?.layer?.removeAnimation(forKey: "switcherScaleOut")
        hostingView?.layer?.setAffineTransform(.identity)
        alphaValue = 0
        if presentationMode == .workspace {
            makeKeyAndOrderFront(nil)
            makeFirstResponder(hostingView)
        } else {
            orderFrontRegardless()
        }

        let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
        scaleAnimation.fromValue = 0.985
        scaleAnimation.toValue = 1.0
        scaleAnimation.duration = entranceDuration
        scaleAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        hostingView?.layer?.add(scaleAnimation, forKey: "switcherScaleIn")

        NSAnimationContext.runAnimationGroup { context in
            context.duration = entranceDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    private func dismissWithExitAnimation() {
        guard isVisible else {
            alphaValue = 0
            orderOut(nil)
            return
        }

        hostingView?.layer?.removeAnimation(forKey: "switcherScaleIn")
        let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
        scaleAnimation.fromValue = 1.0
        scaleAnimation.toValue = 0.985
        scaleAnimation.duration = dismissalDuration
        scaleAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        hostingView?.layer?.add(scaleAnimation, forKey: "switcherScaleOut")

        NSAnimationContext.runAnimationGroup { context in
            context.duration = dismissalDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.hostingView?.layer?.setAffineTransform(.identity)
                self?.orderOut(nil)
            }
        }
    }

    private func startClickOutsideMonitor() {
        // Monitor for mouse clicks outside the panel
        // Posts notification so SwitcherPanelManager can check ALL panels before dismissing
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.isVisible else { return }

            let screenLocation = NSEvent.mouseLocation

            // Post notification with click location - manager will check all panels
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .clickOutsideDetected,
                    object: nil,
                    userInfo: ["location": screenLocation]
                )
            }
        }
    }

    private func stopClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    func selectNext() {
        AppState.shared.selectNextApp()
    }

    func selectPrevious() {
        AppState.shared.selectPreviousApp()
    }

    func selectNextWindow() {
        AppState.shared.selectNextWindow()
    }

    func selectPreviousWindow() {
        AppState.shared.selectPreviousWindow()
    }

    func activateSearch() {
        presentationMode = .workspace
        applyWindowLevel(for: .workspace)
        AppState.shared.isSearchActive = true
        // Make the panel key to receive keyboard input
        makeKeyAndOrderFront(nil)
    }

    func confirmSelection() {
        guard let app = AppState.shared.selectedApp else {
            hide()
            // Notify that we're done (so event tap updates its state)
            NotificationCenter.default.post(name: .switcherConfirmedByMouseClick, object: nil)
            return
        }

        let windowIndex = AppState.shared.selectedWindowIndex

        // Hide first for responsiveness
        hide()

        // Notify that we confirmed via mouse click (so event tap updates its state)
        // This prevents double-confirm when modifier is released after click
        NotificationCenter.default.post(name: .switcherConfirmedByMouseClick, object: nil)

        // Then switch synchronously
        if app.windows.indices.contains(windowIndex) {
            let window = app.windows[windowIndex]
            WindowSwitcher.shared.switchTo(window: window, in: app, windowIndex: windowIndex)
        } else {
            WindowSwitcher.shared.activate(app: app)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard handleWorkspaceKeyDown(event) else {
            super.keyDown(with: event)
            return
        }
    }

    override func cancelOperation(_ sender: Any?) {
        SwitcherPanelManager.shared.hide()
    }

    private func handleWorkspaceKeyDown(_ event: NSEvent) -> Bool {
        guard AppState.shared.presentationMode == .workspace else { return false }

        let isShiftPressed = event.modifierFlags.contains(.shift)
        switch Int(event.keyCode) {
        case kVK_Escape:
            SwitcherPanelManager.shared.hide()
            return true
        case kVK_Return:
            if AppState.shared.isSearchActive {
                SwitcherPanelManager.shared.confirmSelection()
            } else {
                NotificationCenter.default.post(name: .activateSwitcherSearch, object: nil)
            }
            return true
        case kVK_Tab:
            if AppState.shared.isSearchActive && !AppState.shared.searchQuery.isEmpty {
                isShiftPressed ? AppState.shared.selectPreviousApp() : AppState.shared.selectNextApp()
            } else {
                isShiftPressed ? AppState.shared.selectPreviousApp() : AppState.shared.selectNextApp()
            }
            return true
        case kVK_LeftArrow:
            AppState.shared.selectPreviousApp()
            return true
        case kVK_RightArrow:
            AppState.shared.selectNextApp()
            return true
        case kVK_UpArrow:
            if AppState.shared.isSearchActive && !AppState.shared.searchQuery.isEmpty {
                AppState.shared.selectPreviousApp()
            } else {
                AppState.shared.selectPreviousWindow()
            }
            return true
        case kVK_DownArrow:
            if AppState.shared.isSearchActive && !AppState.shared.searchQuery.isEmpty {
                AppState.shared.selectNextApp()
            } else {
                AppState.shared.selectNextWindow()
            }
            return true
        case kVK_ANSI_Grave:
            isShiftPressed ? AppState.shared.selectPreviousWindow() : AppState.shared.selectNextWindow()
            return true
        default:
            return false
        }
    }
}
