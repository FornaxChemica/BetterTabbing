import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var eventTap: KeyboardEventTap?
    private var panelManager: SwitcherPanelManager { SwitcherPanelManager.shared }
    private var preferencesWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    private var isNativeCommandTabSessionActive = false
    private var nativeFallbackWorkItem: DispatchWorkItem?
    private var nativeWindowSelectionWasAdjusted = false
    private var lastWorkspaceWindowIndexByPID: [pid_t: Int] = [:]
    private var hasStartedWindowCache = false
    private var onboardingWindow: NSWindow?
    private var permissionReadyWindow: NSWindow?
    private var permissionMonitorTimer: Timer?
    private var hasCompletedPermissionGate = false
    private var isEventTapSuspendedForMissingInput = false
    private var hasShownReadyWindowThisLaunch = false
    private var lastPermissionAllGranted: Bool?
    private var lastLoggedPermissionStatusDescription: String?
    private let dockProcessSwitcherObserver = DockProcessSwitcherObserver()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock
        NSApp.setActivationPolicy(.accessory)

        setupEventTap()
        setupWorkspaceRecoveryObservers()
        startPermissionMonitoring()
        eventTap?.logStartupDiagnostics(context: "applicationDidFinishLaunching")

        Task { @MainActor in
            await refreshPermissionGate(context: "launch")
        }

        // Panel manager is a lazy singleton - will create panels on first show.
        print("[WindowLens] App initialized successfully")
    }

    func applicationWillTerminate(_ notification: Notification) {
        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        for token in workspaceObserverTokens {
            workspaceNotificationCenter.removeObserver(token)
        }
        workspaceObserverTokens.removeAll()

        dockProcessSwitcherObserver.stop()
        eventTap?.disable()
        permissionMonitorTimer?.invalidate()
        permissionMonitorTimer = nil
        print("[WindowLens] App terminating")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        eventTap?.resetShortcutState(reason: "application did become active")
        Task { @MainActor in
            await refreshPermissionGate(context: "application active")
        }
    }

    func applicationWillResignActive(_ notification: Notification) {
        eventTap?.resetShortcutState(reason: "application will resign active")
    }

    deinit {
        print("[WindowLens] AppDelegate deinit")
    }

    private func logLaunchDiagnostics(status: PermissionManager.Status, context: String) {
        let bundle = Bundle.main
        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "unknown"
        let executableName = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? "unknown"
        let bundleIdentifier = bundle.bundleIdentifier ?? "unknown"
        print("[WindowLens][\(context)] displayName=\(displayName) executable=\(executableName) bundleID=\(bundleIdentifier)")
        print("[WindowLens][\(context)] AXIsProcessTrusted=\(status.accessibility)")
        print("[WindowLens][\(context)] IOHIDCheckAccess.listenEvent=\(status.inputMonitoring)")
        print("[WindowLens][\(context)] CGPreflightScreenCaptureAccess=\(status.screenRecording)")
    }

    private func startPermissionMonitoring() {
        guard permissionMonitorTimer == nil else { return }

        permissionMonitorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshPermissionGate(context: "permission monitor")
            }
        }

        print("[WindowLens] Permission monitor started")
    }

    private func refreshPermissionGate(context: String) async {
        let status = await PermissionManager.shared.checkStatus()
        let previousAllGranted = lastPermissionAllGranted
        let didTransitionToMissing = previousAllGranted == true && !status.allGranted
        let didTransitionToGranted = previousAllGranted == false && status.allGranted
        let statusDescription = status.description
        let shouldLogStatus = context != "permission monitor"
            || didTransitionToMissing
            || didTransitionToGranted
            || lastLoggedPermissionStatusDescription != statusDescription

        lastPermissionAllGranted = status.allGranted

        if shouldLogStatus {
            logLaunchDiagnostics(status: status, context: context)
            lastLoggedPermissionStatusDescription = statusDescription
        }

        guard status.allGranted else {
            hasCompletedPermissionGate = false

            if didTransitionToMissing {
                if AppState.shared.isVisible {
                    panelManager.hide()
                } else {
                    panelManager.scheduleIdlePreviewMemoryTrim(reason: "permission loss")
                }
            }

            if !status.accessibility, hasStartedWindowCache {
                WindowCache.shared.stopMonitoring()
                hasStartedWindowCache = false
                WindowVisitHistory.shared.stopMonitoring()
                print("[WindowLens] WindowCache monitoring stopped: Accessibility permission is missing")
            }

            if !status.inputMonitoring {
                if !isEventTapSuspendedForMissingInput {
                    eventTap?.suspend(reason: "Input Monitoring permission missing")
                    isEventTapSuspendedForMissingInput = true
                } else {
                    eventTap?.resetShortcutState(reason: "Input Monitoring permission still missing")
                }
            } else {
                isEventTapSuspendedForMissingInput = false
            }

            if shouldLogStatus {
                print("[WindowLens] Permission gate blocked context=\(context):\n\(status.description)")
            }

            closePermissionReadyWindow()
            showPermissionOnboardingWindow(
                activate: shouldActivatePermissionWindow(context: context) || didTransitionToMissing
            )
            return
        }

        isEventTapSuspendedForMissingInput = false
        guard !hasCompletedPermissionGate
            || didTransitionToGranted
            || context != "permission monitor" else {
            return
        }

        proceedAfterPermissions(status: status, context: context)
    }

    private func shouldActivatePermissionWindow(context: String) -> Bool {
        context == "launch" || context == "application active"
    }

    private func showPermissionOnboardingWindow(activate: Bool) {
        if let window = onboardingWindow {
            if activate {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }

        let view = PermissionOnboardingView { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let status = await PermissionManager.shared.checkStatus()
                guard status.allGranted else {
                    self.showPermissionOnboardingWindow(activate: true)
                    return
                }

                self.closePermissionOnboardingWindow()
                self.proceedAfterPermissions(status: status, context: "onboarding complete")
            }
        }

        let window = makePermissionGlassWindow(
            title: "Welcome to WindowLens",
            styleMask: [.titled, .fullSizeContentView],
            rootView: view
        )
        window.center()

        onboardingWindow = window
        if activate {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.orderFront(nil)
        }
        print("[WindowLens] Permission onboarding window shown")
    }

    private func closePermissionOnboardingWindow() {
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    private func showPermissionReadyWindow() {
        guard !hasShownReadyWindowThisLaunch else { return }
        hasShownReadyWindowThisLaunch = true

        if let window = permissionReadyWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = PermissionReadyView { [weak self] in
            self?.closePermissionReadyWindow()
        }
        let window = makePermissionGlassWindow(
            title: "WindowLens is Ready",
            styleMask: [.titled, .closable, .fullSizeContentView],
            rootView: view
        )
        window.center()

        permissionReadyWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        print("[WindowLens] Permission ready window shown")
    }

    private func closePermissionReadyWindow() {
        permissionReadyWindow?.close()
        permissionReadyWindow = nil
    }

    private func makePermissionGlassWindow<Content: View>(
        title: String,
        styleMask: NSWindow.StyleMask,
        rootView: Content
    ) -> NSWindow {
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = title
        window.styleMask = styleMask
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        return window
    }

    private func proceedAfterPermissions(status: PermissionManager.Status, context: String) {
        guard status.allGranted else {
            hasCompletedPermissionGate = false
            showPermissionOnboardingWindow(activate: shouldActivatePermissionWindow(context: context))
            return
        }

        if !hasCompletedPermissionGate {
            print("[WindowLens] Permission gate completed context=\(context)")
        }
        hasCompletedPermissionGate = true

        startWindowCacheIfAccessibilityTrusted(status: status, context: context)
        WindowVisitHistory.shared.startMonitoring()

        if eventTap?.isInstalled == true {
            eventTap?.verifyOrRebuild(reason: "permissions confirmed \(context)")
        } else {
            eventTap?.scheduleInstall(reason: "permissions confirmed \(context)", delay: 0.5)
        }

        if context == "launch" || context == "onboarding complete" {
            showPermissionReadyWindow()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            return
        }

        if window === onboardingWindow {
            onboardingWindow = nil
        } else if window === permissionReadyWindow {
            permissionReadyWindow = nil
        }
    }

    private func startWindowCacheIfAccessibilityTrusted(
        status: PermissionManager.Status,
        context: String
    ) {
        guard status.accessibility else {
            print("[WindowLens] WindowCache startup skipped: Accessibility is not granted context=\(context)")
            return
        }

        guard !hasStartedWindowCache else { return }
        hasStartedWindowCache = true
        WindowCache.shared.startMonitoring()
        WindowCache.shared.prefetchAsync()
        print("[WindowLens] WindowCache monitoring started context=\(context)")
    }

    private func setupEventTap() {
        print("[WindowLens] Creating KeyboardEventTap manager")
        eventTap = KeyboardEventTap()

        eventTap?.onShortcutTriggered
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handleShortcutEvent(event)
                }
            }
            .store(in: &cancellables)

        // Listen for click-outside-to-dismiss notifications
        NotificationCenter.default.publisher(for: .switcherDismissedByClickOutside)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.eventTap?.setSwitcherVisible(false)
                }
            }
            .store(in: &cancellables)

        // Listen for mouse-click confirmation notifications
        // This prevents double-confirm when modifier is released after clicking
        NotificationCenter.default.publisher(for: .switcherConfirmedByMouseClick)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.eventTap?.setSwitcherVisible(false)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .workspaceWindowActivated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let pid = notification.userInfo?["pid"] as? pid_t,
                          let windowIndex = notification.userInfo?["windowIndex"] as? Int else {
                        return
                    }
                    self?.recordWorkspaceWindowActivation(pid: pid, windowIndex: windowIndex)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .reinstallEventTap)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                _ = Task<Void, Never> { @MainActor [weak self] in
                    guard let self else { return }
                    let status = await PermissionManager.shared.checkStatus()
                    if status.allGranted {
                        self.eventTap?.verifyOrRebuild(reason: "manual menu action")
                    } else {
                        self.showPermissionOnboardingWindow(activate: true)
                    }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .openPermissions)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.showPermissionOnboardingWindow(activate: true)
                }
            }
            .store(in: &cancellables)

        // Listen for activation modifier changes from preferences
        NotificationCenter.default.publisher(for: .activationModifierChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                MainActor.assumeIsolated {
                    if let modifier = notification.userInfo?["modifier"] as? ModifierKey {
                        self?.eventTap?.setActivationModifier(modifier)
                        print("[WindowLens] Activation modifier changed to: \(modifier.symbol)")
                    }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .activateSwitcherSearch)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.panelManager.activateSearch()
                    self?.eventTap?.setSearchModeActive(true)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .workspaceActiveApplicationDidReconcile)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self,
                          let pid = notification.userInfo?["pid"] as? pid_t,
                          let applications = notification.userInfo?["applications"] as? [ApplicationModel] else {
                        return
                    }

                    guard !self.isNativeCommandTabSessionActive else {
                        print("[WindowLens] Live MRU updated during native Cmd+Tab; visible snapshot remains frozen")
                        return
                    }

                    self.panelManager.reconcileSystemActivation(
                        applications: applications,
                        activePID: pid
                    )
                }
            }
            .store(in: &cancellables)

        dockProcessSwitcherObserver.onSelectionChanged = { [weak self] selection in
            MainActor.assumeIsolated {
                self?.handleDockProcessSwitcherSelection(selection)
            }
        }
        dockProcessSwitcherObserver.onSwitcherDestroyed = { [weak self] in
            MainActor.assumeIsolated {
                self?.endNativeCommandTabSession(applySelectedWindow: false)
            }
        }

        // Option+Tab owns WindowLens workspace mode. Cmd+Tab remains native and
        // is observed passively by the event tap.
        eventTap?.setActivationModifier(.option)
        print("[WindowLens] Loaded workspace activation modifier: \(ModifierKey.option.symbol)")

        // Listen for open preferences notification
        NotificationCenter.default.publisher(for: .openPreferences)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    print("[WindowLens] Opening preferences window")
                    self?.showPreferencesWindow()
                }
            }
            .store(in: &cancellables)

        print("[WindowLens] Event tap configured")
        eventTap?.logStartupDiagnostics(context: "setupEventTap complete")
    }

    private func setupWorkspaceRecoveryObservers() {
        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter

        let sessionToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("[WindowLens] NSWorkspace session became active; refreshing permission gate")
            Task { @MainActor [weak self] in
                await self?.refreshPermissionGate(context: "workspace session became active")
            }
        }

        let wakeToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("[WindowLens] NSWorkspace did wake; refreshing permission gate")
            Task { @MainActor [weak self] in
                await self?.refreshPermissionGate(context: "workspace did wake")
            }
        }

        workspaceObserverTokens = [sessionToken, wakeToken]
        print("[WindowLens] Workspace recovery observers installed")
    }

    private func showPreferencesWindow() {
        // If window exists and is visible, just bring it to front
        if let window = preferencesWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create new preferences window
        let preferencesView = PreferencesView()
            .environmentObject(AppState.shared)

        let hostingController = NSHostingController(rootView: preferencesView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "WindowLens Preferences"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 450, height: 320))
        window.center()
        window.isReleasedWhenClosed = false

        preferencesWindow = window

        // Show the window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        print("[WindowLens] Preferences window shown")
    }

    private func handleShortcutEvent(_ event: ShortcutEvent) {
        print("[WindowLens] Shortcut event: \(event)")

        switch event {
        case .activationStarted:
            break
        case .showSwitcher:
            startWorkspaceWindowSession(showImmediately: true)
            eventTap?.setSwitcherVisible(true)
        case .cycleNext:
            if AppState.shared.presentationMode == .workspace,
               AppState.shared.workspaceMode == .currentAppWindows {
                panelManager.selectNextWindow()
            } else {
                panelManager.selectNext()
            }
        case .cyclePrevious:
            if AppState.shared.presentationMode == .workspace,
               AppState.shared.workspaceMode == .currentAppWindows {
                panelManager.selectPreviousWindow()
            } else {
                panelManager.selectPrevious()
            }
        case .cycleWindowNext:
            panelManager.selectNextWindow()
        case .cycleWindowPrevious:
            panelManager.selectPreviousWindow()
        case .activateSearch:
            pinWorkspaceSearch()
        case .pinWorkspaceSearch:
            pinWorkspaceSearch()
        case .workspaceSearchScopeCurrentApp:
            AppState.shared.setWorkspaceSearchScope(.currentApp)
        case .workspaceSearchScopeAllWindows:
            AppState.shared.setWorkspaceSearchScope(.allWindows)
        case .confirm:
            panelManager.confirmSelection()
            eventTap?.setSwitcherVisible(false)
        case .dismiss:
            panelManager.hide()
            eventTap?.setSwitcherVisible(false)
        case .navigateUp:
            // Navigate up in search results (same as selectPrevious)
            panelManager.selectPrevious()
        case .navigateDown:
            // Navigate down in search results (same as selectNext)
            panelManager.selectNext()
        case .navigateRowUp:
            AppState.shared.selectPreviousWindow()
        case .navigateRowDown:
            AppState.shared.selectNextWindow()
        case .quickSwitch:
            // Quick Option+Tab switches within the frontmost app, never across apps.
            eventTap?.setSwitcherVisible(false)
            performCurrentAppWindowQuickSwitch()
        case .quitHoldStarted:
            AppState.shared.startQuitHold()
        case .quitHoldCancelled:
            AppState.shared.cancelQuitHold()
        case .toggleResourceMonitor:
            AppState.shared.cancelEHold(triggeredAI: false)
            AppState.shared.toggleResourceMonitor()
        case .eHoldStarted:
            AppState.shared.startEHold()
        case .aiInsightRequested:
            AppState.shared.cancelEHold(triggeredAI: true)
            AppState.shared.requestAIInsightWithOllama()
        case .aiInsightCancelled:
            AppState.shared.cancelEHold(triggeredAI: false)
        case .toggleProcessGrouping:
            AppState.shared.isProcessGroupingEnabled.toggle()
        case .nativeSwitchStarted(let reverse):
            startNativeCommandTabSession(reverse: reverse)
        case .nativeSwitchCycleNext:
            scheduleProvisionalNativeFallback(reverse: false)
        case .nativeSwitchCyclePrevious:
            scheduleProvisionalNativeFallback(reverse: true)
        case .nativeSwitchWindowNext:
            selectNativeWindow(reverse: false)
        case .nativeSwitchWindowPrevious:
            selectNativeWindow(reverse: true)
        case .nativeSwitchEnded:
            endNativeCommandTabSession(applySelectedWindow: true)
        case .windowHistoryUndo:
            performWindowHistoryUndo()
        case .windowHistoryRedo:
            performWindowHistoryRedo()
        }
    }

    private func performWindowHistoryUndo() {
        guard !AppState.shared.isVisible else { return }
        let outcome = WindowVisitHistory.shared.undo()
        WindowHistoryHUD.shared.present(outcome: outcome)
    }

    private func performWindowHistoryRedo() {
        guard !AppState.shared.isVisible else { return }
        let outcome = WindowVisitHistory.shared.redo()
        WindowHistoryHUD.shared.present(outcome: outcome)
    }

    private func startWorkspaceWindowSession(showImmediately: Bool) {
        var snapshot = WindowCache.shared.getApplicationsForWorkspaceSwitching()
        let frontmost = frontmostApplicationForWorkspace()
        if let frontmost,
           !snapshot.contains(where: { $0.pid == frontmost.processIdentifier || $0.bundleIdentifier == frontmost.bundleIdentifier }) {
            snapshot.insert(workspacePlaceholderApplication(for: frontmost), at: 0)
        }
        let frontmostApp = frontmost.flatMap { runningApp in
            snapshot.first {
                $0.pid == runningApp.processIdentifier
                    || $0.bundleIdentifier == runningApp.bundleIdentifier
            }
        }
        let initialWindowIndex = frontmostApp.flatMap { nextWindowIndexForWorkspaceSession(in: $0) }

        AppState.shared.beginWorkspaceWindowSession(
            snapshot: snapshot,
            frontmostPID: frontmost?.processIdentifier,
            visible: showImmediately,
            initialWindowIndex: initialWindowIndex
        )

        if let selectedApp = AppState.shared.selectedApp {
            requestSelectedNativeAppPreviews(selectedApp)
        }

        WindowCache.shared.prefetchAsync()

        guard showImmediately else { return }
        panelManager.showCurrentAppWindowSwitcher()
    }

    private func pinWorkspaceSearch() {
        AppState.shared.pinWorkspaceSearch()
        panelManager.activateSearch()
        eventTap?.setSearchModeActive(true)
    }

    private func frontmostApplicationForWorkspace() -> NSRunningApplication? {
        let currentBundleIdentifier = Bundle.main.bundleIdentifier
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.activationPolicy == .regular,
           frontmost.bundleIdentifier != currentBundleIdentifier {
            return frontmost
        }

        return NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular
                && $0.isActive
                && $0.bundleIdentifier != currentBundleIdentifier
        }
    }

    private func performCurrentAppWindowQuickSwitch() {
        let snapshot = WindowCache.shared.getApplicationsForWorkspaceSwitching()
        guard let frontmost = frontmostApplicationForWorkspace(),
              let app = snapshot.first(where: {
                  $0.pid == frontmost.processIdentifier
                      || $0.bundleIdentifier == frontmost.bundleIdentifier
              }) else {
            WindowCache.shared.prefetchAsync()
            return
        }

        let realWindowIndices = realWindowIndices(in: app)
        guard realWindowIndices.count > 1,
              let targetIndex = nextWindowIndexForWorkspaceSession(in: app) else {
            WindowCache.shared.prefetchAsync()
            return
        }

        recordWorkspaceWindowActivation(pid: app.pid, windowIndex: targetIndex)
        WindowSwitcher.shared.switchTo(
            window: app.windows[targetIndex],
            in: app,
            windowIndex: targetIndex
        )
    }

    private func recordWorkspaceWindowActivation(pid: pid_t, windowIndex: Int) {
        lastWorkspaceWindowIndexByPID[pid] = windowIndex
    }

    private func nextWindowIndexForWorkspaceSession(in app: ApplicationModel) -> Int? {
        let realIndices = realWindowIndices(in: app)
        guard !realIndices.isEmpty else { return nil }
        guard realIndices.count > 1 else { return realIndices[0] }

        let currentIndex = focusedWindowIndex(in: app)
            ?? validLastWorkspaceWindowIndex(for: app, realIndices: realIndices)
            ?? realIndices[0]

        guard let position = realIndices.firstIndex(of: currentIndex) else {
            return realIndices[0]
        }

        return realIndices[(position + 1) % realIndices.count]
    }

    private func realWindowIndices(in app: ApplicationModel) -> [Int] {
        app.windows.indices.filter { !app.windows[$0].isWindowlessPlaceholder }
    }

    private func validLastWorkspaceWindowIndex(for app: ApplicationModel, realIndices: [Int]) -> Int? {
        guard let lastIndex = lastWorkspaceWindowIndexByPID[app.pid],
              realIndices.contains(lastIndex) else {
            return nil
        }
        return lastIndex
    }

    private func focusedWindowIndex(in app: ApplicationModel) -> Int? {
        guard let focusedWindow = AXWindowHelper.focusedWindowSnapshot(for: app.pid) else {
            return nil
        }

        if focusedWindow.hasReliableWindowID,
           let index = app.windows.firstIndex(where: {
               !$0.isWindowlessPlaceholder
                   && $0.previewIdentity.hasReliableCGWindowID
                   && $0.windowID == focusedWindow.windowID
           }) {
            return index
        }

        let focusedIdentity = PreviewIdentity(
            ownerPID: app.pid,
            bundleIdentifier: app.bundleIdentifier,
            cgWindowID: focusedWindow.windowID,
            title: focusedWindow.title,
            bounds: focusedWindow.bounds,
            hasReliableCGWindowID: focusedWindow.hasReliableWindowID
        )

        if let index = app.windows.firstIndex(where: {
            !$0.isWindowlessPlaceholder && $0.previewIdentity.matches(focusedIdentity)
        }) {
            return index
        }

        return fuzzyFocusedWindowIndex(focusedWindow, in: app)
    }

    private func fuzzyFocusedWindowIndex(
        _ focusedWindow: AXWindowHelper.FocusedWindowSnapshot,
        in app: ApplicationModel
    ) -> Int? {
        let focusedTitle = PreviewIdentity.normalizedTitle(focusedWindow.title)
        let hasFocusedTitle = !focusedTitle.isEmpty

        let candidates = app.windows.indices
            .filter { !app.windows[$0].isWindowlessPlaceholder }
            .map { index -> (index: Int, score: CGFloat) in
                let window = app.windows[index]
                let windowTitle = PreviewIdentity.normalizedTitle(window.title)
                var score: CGFloat = 0

                if hasFocusedTitle && !windowTitle.isEmpty {
                    if windowTitle == focusedTitle {
                        score += 0
                    } else if windowTitle.contains(focusedTitle) || focusedTitle.contains(windowTitle) {
                        score += 8
                    } else {
                        score += 42
                    }
                } else {
                    score += 12
                }

                if focusedWindow.bounds.width > 1, focusedWindow.bounds.height > 1,
                   window.bounds.width > 1, window.bounds.height > 1 {
                    score += min(abs(window.bounds.width - focusedWindow.bounds.width) / 12, 32)
                    score += min(abs(window.bounds.height - focusedWindow.bounds.height) / 12, 32)
                    score += min(abs(window.bounds.minX - focusedWindow.bounds.minX) / 80, 16)
                    score += min(abs(window.bounds.minY - focusedWindow.bounds.minY) / 80, 16)
                }

                return (index, score)
            }
            .sorted { lhs, rhs in lhs.score < rhs.score }

        guard let best = candidates.first, best.score <= 48 else { return nil }
        return best.index
    }

    private func workspacePlaceholderApplication(for runningApplication: NSRunningApplication) -> ApplicationModel {
        let pid = runningApplication.processIdentifier
        let bundleIdentifier = runningApplication.bundleIdentifier ?? "windowlens.workspace.placeholder.\(pid)"
        let appName = runningApplication.localizedName ?? "Current App"
        let icon = runningApplication.icon
            ?? NSImage(named: NSImage.applicationIconName)
            ?? NSImage()
        let windowTitle = "No Windows"
        let windowID = PreviewIdentity.pseudoWindowID(
            ownerPID: pid,
            axIndex: 0,
            title: windowTitle,
            bounds: .zero
        )
        let placeholderWindow = WindowModel(
            windowID: windowID,
            title: windowTitle,
            bounds: .zero,
            isMinimized: false,
            isOnScreen: false,
            ownerPID: pid,
            bundleIdentifier: bundleIdentifier,
            axIndex: 0,
            hasReliableWindowID: false,
            previewImage: nil,
            subtitle: "No Windows"
        )

        return ApplicationModel(
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            name: appName,
            icon: icon,
            windows: [placeholderWindow],
            isActive: runningApplication.isActive
        )
    }

    private func startNativeCommandTabSession(reverse: Bool) {
        isNativeCommandTabSessionActive = true
        nativeWindowSelectionWasAdjusted = false
        nativeFallbackWorkItem?.cancel()
        nativeFallbackWorkItem = nil

        dockProcessSwitcherObserver.start()

        let applications = WindowCache.shared.getApplicationsForNativePreview()
        panelManager.showNativePreview(applications: applications, showImmediately: false)
        prewarmPreviews(for: applications)
        WindowCache.shared.prefetchAsync()

        scheduleProvisionalNativeFallback(reverse: reverse, delay: 0.14)
    }

    private func handleDockProcessSwitcherSelection(_ selection: DockProcessSwitcherSelection) {
        guard isNativeCommandTabSessionActive else { return }

        nativeFallbackWorkItem?.cancel()
        nativeFallbackWorkItem = nil

        guard panelManager.selectNativeDockSelection(selection) else {
            return
        }

        if let selectedApp = AppState.shared.selectedApp {
            requestSelectedNativeAppPreviews(selectedApp)
        }
    }

    private func scheduleProvisionalNativeFallback(reverse: Bool, delay: TimeInterval = 0.14) {
        guard isNativeCommandTabSessionActive else { return }

        nativeFallbackWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.isNativeCommandTabSessionActive,
                      !self.dockProcessSwitcherObserver.hasDeliveredSelection else {
                    return
                }

                if reverse {
                    self.panelManager.selectPrevious()
                } else {
                    self.panelManager.selectNext()
                }

                if let selectedApp = AppState.shared.selectedApp {
                    self.requestSelectedNativeAppPreviews(selectedApp)
                    self.panelManager.showNativeFallbackPreviewPanel()
                }
            }
        }
        nativeFallbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func selectNativeWindow(reverse: Bool) {
        guard isNativeCommandTabSessionActive else { return }

        let previousIndex = AppState.shared.selectedWindowIndex
        if reverse {
            panelManager.selectPreviousWindow()
        } else {
            panelManager.selectNextWindow()
        }
        nativeWindowSelectionWasAdjusted = nativeWindowSelectionWasAdjusted
            || AppState.shared.selectedWindowIndex != previousIndex

        if let selectedApp = AppState.shared.selectedApp {
            requestSelectedNativeAppPreviews(selectedApp)
        }
    }

    private func requestSelectedNativeAppPreviews(_ app: ApplicationModel) {
        guard !app.windows.isEmpty else { return }
        AppState.shared.hydrateCachedPreviews(for: app.pid)

        guard let hydratedApp = AppState.shared.applications.first(where: { $0.pid == app.pid }),
              !hydratedApp.windows.isEmpty else {
            return
        }

        WindowPreviewService.shared.requestPreviews(
            for: hydratedApp.windows,
            ownerPID: hydratedApp.pid,
            appName: hydratedApp.name,
            selectionGeneration: AppState.shared.currentNativePreviewGeneration
        )
    }

    private func prewarmPreviews(for applications: [ApplicationModel]) {
        let appsToPrewarm = applications.prefix(8)
        for app in appsToPrewarm {
            let windows = Array(app.windows.prefix(3))
            guard !windows.isEmpty else { continue }
            WindowPreviewService.shared.requestPreviews(
                for: windows,
                ownerPID: app.pid,
                appName: app.name,
                selectionGeneration: AppState.shared.currentNativePreviewGeneration
            )
        }

        WindowCache.shared.prefetchAsync()
    }

    private func reconcileNativeCommandTabRelease() {
        panelManager.finishNativeTraversalAndReconcileFrontmost()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            MainActor.assumeIsolated {
                self?.panelManager.reconcileFrontmostApplication()
            }
        }
    }

    private func endNativeCommandTabSession(applySelectedWindow: Bool) {
        guard isNativeCommandTabSessionActive else { return }

        let currentSelectedWindow = AppState.shared.selectedNativeWindowSelection()
        let shouldApplySelectedWindow = applySelectedWindow
            && (nativeWindowSelectionWasAdjusted || currentSelectedWindow?.window.isMinimized == true)
        let selectedWindow = shouldApplySelectedWindow ? currentSelectedWindow : nil

        isNativeCommandTabSessionActive = false
        nativeFallbackWorkItem?.cancel()
        nativeFallbackWorkItem = nil
        nativeWindowSelectionWasAdjusted = false
        dockProcessSwitcherObserver.stop()
        reconcileNativeCommandTabRelease()
        panelManager.hide()
        eventTap?.setSwitcherVisible(false)

        if let selectedWindow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                WindowSwitcher.shared.switchTo(
                    window: selectedWindow.window,
                    in: selectedWindow.app,
                    windowIndex: selectedWindow.index
                )
            }
        }
    }

    private func performQuickSwitch() {
        // Use cached data (lock-free read) - don't wait for any prefetch
        let apps = WindowCache.shared.getCachedApplications()

        guard apps.count > 1 else {
            print("[WindowLens] Quick switch: Not enough apps (have \(apps.count))")
            return
        }

        // Get the ACTUAL current frontmost app to ensure we switch to something different
        // This is critical because the cache MRU order might be slightly stale
        let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // Find the first app in the MRU list that is NOT the current frontmost app
        var targetApp: ApplicationModel?
        for app in apps {
            if app.pid != frontmostPid {
                targetApp = app
                break
            }
        }

        guard let previousApp = targetApp else {
            print("[WindowLens] Quick switch: No different app to switch to")
            return
        }

        print("[WindowLens] Quick switch to: \(previousApp.name)")

        // Activate synchronously for speed
        WindowSwitcher.shared.activate(app: previousApp)
    }
}
