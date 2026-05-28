import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var eventTap: KeyboardEventTap?
    private var panelManager: SwitcherPanelManager { SwitcherPanelManager.shared }
    private var preferencesWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var workspaceObserverTokens: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock
        NSApp.setActivationPolicy(.accessory)

        // Initialize event infrastructure early, but install the CGEventTap after
        // a short launch delay to avoid TCC/LaunchServices races after signing changes.
        setupEventTap()
        setupWorkspaceRecoveryObservers()
        eventTap?.logStartupDiagnostics(context: "applicationDidFinishLaunching")
        eventTap?.scheduleInstall(reason: "delayed app launch", delay: 1.0)

        // Check/request permissions
        Task { @MainActor in
            let status = await PermissionManager.shared.checkStatus()
            print("[BetterTabbing] Permission status on launch:\n\(status.description)")
            eventTap?.logStartupDiagnostics(context: "permission check before request")

            if !status.allGranted {
                await PermissionManager.shared.requestPermissions()
            }

            let updatedStatus = await PermissionManager.shared.checkStatus()
            print("[BetterTabbing] Permission status after request:\n\(updatedStatus.description)")
            eventTap?.logStartupDiagnostics(context: "permission check after request")

            if updatedStatus.inputMonitoring {
                eventTap?.scheduleInstall(reason: "permissions confirmed", delay: 1.0)
            } else {
                print("[BetterTabbing] Event tap not installed: Input Monitoring is not granted")
            }
        }

        // Panel manager is a lazy singleton - will create panels on first show

        // Pre-warm the cache on startup so first activation is fast
        WindowCache.shared.prefetchAsync()
        WindowCache.shared.startMonitoring()

        print("[BetterTabbing] App initialized successfully")
    }

    func applicationWillTerminate(_ notification: Notification) {
        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        for token in workspaceObserverTokens {
            workspaceNotificationCenter.removeObserver(token)
        }
        workspaceObserverTokens.removeAll()

        eventTap?.disable()
        print("[BetterTabbing] App terminating")
    }

    deinit {
        print("[BetterTabbing] AppDelegate deinit")
    }

    private func setupEventTap() {
        print("[BetterTabbing] Creating KeyboardEventTap manager")
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

        // Listen for activation modifier changes from preferences
        NotificationCenter.default.publisher(for: .activationModifierChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                MainActor.assumeIsolated {
                    if let modifier = notification.userInfo?["modifier"] as? ModifierKey {
                        self?.eventTap?.setActivationModifier(modifier)
                        print("[BetterTabbing] Activation modifier changed to: \(modifier.symbol)")
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

        // Option+Tab owns BetterTabbing workspace mode. Cmd+Tab remains native and
        // is observed passively by the event tap.
        eventTap?.setActivationModifier(.option)
        print("[BetterTabbing] Loaded workspace activation modifier: \(ModifierKey.option.symbol)")

        // Listen for open preferences notification
        NotificationCenter.default.publisher(for: .openPreferences)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    print("[BetterTabbing] Opening preferences window")
                    self?.showPreferencesWindow()
                }
            }
            .store(in: &cancellables)

        print("[BetterTabbing] Event tap configured")
        eventTap?.logStartupDiagnostics(context: "setupEventTap complete")
    }

    private func setupWorkspaceRecoveryObservers() {
        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter

        let sessionToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("[BetterTabbing] NSWorkspace session became active; verifying event tap")
            Task { @MainActor [weak self] in
                self?.eventTap?.verifyOrRebuild(reason: "workspace session became active")
            }
        }

        let wakeToken = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            print("[BetterTabbing] NSWorkspace did wake; verifying event tap")
            Task { @MainActor [weak self] in
                self?.eventTap?.verifyOrRebuild(reason: "workspace did wake")
            }
        }

        workspaceObserverTokens = [sessionToken, wakeToken]
        print("[BetterTabbing] Workspace recovery observers installed")
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
        window.title = "BetterTabbing Preferences"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 450, height: 320))
        window.center()
        window.isReleasedWhenClosed = false

        preferencesWindow = window

        // Show the window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        print("[BetterTabbing] Preferences window shown")
    }

    private func handleShortcutEvent(_ event: ShortcutEvent) {
        print("[BetterTabbing] Shortcut event: \(event)")

        switch event {
        case .activationStarted:
            // Pre-fetch window data on background thread (non-blocking)
            WindowCache.shared.prefetchAsync()
        case .showSwitcher:
            panelManager.showWithCachedData(mode: .workspace)
            eventTap?.setSwitcherVisible(true)
        case .cycleNext:
            panelManager.selectNext()
        case .cyclePrevious:
            panelManager.selectPrevious()
        case .cycleWindowNext:
            panelManager.selectNextWindow()
        case .cycleWindowPrevious:
            panelManager.selectPreviousWindow()
        case .activateSearch:
            panelManager.activateSearch()
            eventTap?.setSearchModeActive(true)
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
            // Quick switch to previous app without showing UI
            panelManager.hide()
            eventTap?.setSwitcherVisible(false)
            performQuickSwitch()
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
        case .nativeSwitchStarted:
            WindowCache.shared.prefetchAsync()
            panelManager.showWithCachedData(mode: .nativePreview)
        case .nativeSwitchCycleNext:
            panelManager.selectNext()
        case .nativeSwitchCyclePrevious:
            panelManager.selectPrevious()
        case .nativeSwitchEnded:
            panelManager.hide()
            eventTap?.setSwitcherVisible(false)
        }
    }

    private func performQuickSwitch() {
        // Use cached data (lock-free read) - don't wait for any prefetch
        let apps = WindowCache.shared.getCachedApplications()

        guard apps.count > 1 else {
            print("[BetterTabbing] Quick switch: Not enough apps (have \(apps.count))")
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
            print("[BetterTabbing] Quick switch: No different app to switch to")
            return
        }

        print("[BetterTabbing] Quick switch to: \(previousApp.name)")

        // Activate synchronously for speed
        WindowSwitcher.shared.activate(app: previousApp)
    }
}
