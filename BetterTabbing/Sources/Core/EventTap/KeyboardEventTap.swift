import ApplicationServices
import Carbon.HIToolbox
import Combine
import CoreGraphics
import Foundation

enum ShortcutEvent {
    case activationStarted   // Modifier+Tab pressed - start timer, don't show UI yet
    case showSwitcher        // Timer expired without release - show UI now
    case cycleNext
    case cyclePrevious
    case cycleWindowNext
    case cycleWindowPrevious
    case activateSearch
    case confirm
    case dismiss
    case navigateUp      // Arrow up in search mode
    case navigateDown    // Arrow down in search mode
    case navigateRowUp   // Arrow up in workspace mode - previous window surface
    case navigateRowDown // Arrow down in workspace mode - next window surface
    case quickSwitch     // Quick CMD+TAB to previous app (no UI)
    case quitHoldStarted   // Q key held down - start quit progress
    case quitHoldCancelled // Q key released - cancel quit
    case toggleResourceMonitor // E key tap - toggle mini activity monitor
    case eHoldStarted          // E key pressed - start charging animation
    case aiInsightRequested    // E key held - start ollama + query
    case aiInsightCancelled    // E key released after hold
    case toggleProcessGrouping // F key tap - toggle process grouping in monitor
    case nativeSwitchStarted   // Passive Cmd+Tab observation - never consumes Dock-owned events
    case nativeSwitchCycleNext
    case nativeSwitchCyclePrevious
    case nativeSwitchEnded
}

private final class KeyboardEventTapHealthTarget: NSObject {
    weak var eventTap: KeyboardEventTap?

    init(eventTap: KeyboardEventTap) {
        self.eventTap = eventTap
    }

    @objc func healthTimerFired(_ timer: Timer) {
        eventTap?.verifyOrRebuild(reason: "periodic")
    }
}

final class KeyboardEventTap {
    let onShortcutTriggered = PassthroughSubject<ShortcutEvent, Never>()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthTimer: Timer?
    private var healthTimerTarget: KeyboardEventTapHealthTarget?
    private var installRetryWorkItem: DispatchWorkItem?
    private let modifierTracker = ModifierKeyTracker()
    private var previousFlags: CGEventFlags = []
    private var switcherVisible = false
    private var searchModeActive = false  // When true, don't auto-confirm on modifier release
    private var nativeCommandTabSessionActive = false
    private var callbackCount = 0

    private struct ActivationShortcut {
        let name: String
        let keyCode: UInt16
        let modifiers: Set<ModifierKey>
        let usesShiftForReverse: Bool
        let showsImmediately: Bool
    }

    // Temporary diagnostics while validating event delivery and shortcut matching.
    private let isKeyboardDebugLoggingEnabled = true
    private let debugActivationShortcut = ActivationShortcut(
        name: "Control+Shift+Space",
        keyCode: UInt16(kVK_Space),
        modifiers: [.control, .shift],
        usesShiftForReverse: false,
        showsImmediately: true
    )
    private var activeActivationShortcut: ActivationShortcut?

    // Quick-switch detection
    private var activationTime: CFAbsoluteTime = 0
    private var hadInteractionSinceActivation = false
    private let quickSwitchThreshold: CFAbsoluteTime = 0.12  // 120ms - faster detection
    private var showSwitcherTimer: DispatchWorkItem?
    private var pendingActivation = false  // True between activation and timer/release

    // Quit hold detection
    private var isHoldingQuit = false

    // E key hold detection for AI insight
    private var isHoldingE = false
    private var eKeyDownTime: CFAbsoluteTime = 0
    /// Threshold: hold > 400ms = AI insight request, shorter = toggle monitor
    private let eHoldThreshold: CFAbsoluteTime = 0.4
    private let healthCheckInterval: TimeInterval = 5.0
    private let maxInstallRetryCount = 6
    private var installRetryCount = 0

    // Configuration
    private var activationModifier: ModifierKey = .option  // OPTION+TAB for development
    private let activationKeyCode: UInt16 = UInt16(kVK_Tab)
    private let isCommandTabHandlingEnabled = false

    init() {
        print("[KeyboardEventTap] init")
        logStartupDiagnostics(context: "init")
        startHealthMonitoring()
    }

    deinit {
        print("[KeyboardEventTap] deinit")
        disable()
    }

    var isInstalled: Bool {
        eventTap != nil
    }

    func logStartupDiagnostics(context: String) {
        print("[KeyboardEventTap][\(context)] AXIsProcessTrusted=\(AXIsProcessTrusted())")
        print("[KeyboardEventTap][\(context)] CGPreflightListenEventAccess=\(CGPreflightListenEventAccess())")
        print("[KeyboardEventTap][\(context)] bundleID=\(Bundle.main.bundleIdentifier ?? "unknown")")
        logTapState(context: context)
    }

    func scheduleInstall(reason: String, delay: TimeInterval = 1.0) {
        installRetryWorkItem?.cancel()
        print("[KeyboardEventTap] Scheduling install in \(String(format: "%.1f", delay))s reason=\(reason)")

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let didInstall = self.installIfNeeded(reason: reason)
            if didInstall {
                self.installRetryCount = 0
            } else {
                self.scheduleRetry(afterFailureReason: reason)
            }
        }

        installRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    @discardableResult
    func installIfNeeded(reason: String = "manual") -> Bool {
        if let tap = eventTap {
            if runLoopSource == nil {
                print("[KeyboardEventTap] Event tap exists without run loop source; rebuilding")
                rebuildEventTap(reason: "missing run loop source")
                return eventTap != nil && runLoopSource != nil
            }

            let isEnabled = CGEvent.tapIsEnabled(tap: tap)
            print("[KeyboardEventTap] Event tap already exists reason=\(reason) enabled=\(isEnabled)")
            if !isEnabled {
                print("[KeyboardEventTap] Existing tap disabled; re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
                logTapState(context: "installIfNeeded re-enable")
            }
            return CGEvent.tapIsEnabled(tap: tap)
        }

        return createEventTap(reason: reason)
    }

    func verifyOrRebuild(reason: String) {
        print("[KeyboardEventTap] Health check reason=\(reason)")
        logStartupDiagnostics(context: "health \(reason)")

        guard let tap = eventTap else {
            print("[KeyboardEventTap] Health check found no tap; scheduling install")
            scheduleInstall(reason: "health check missing tap", delay: 0.2)
            return
        }

        guard runLoopSource != nil else {
            print("[KeyboardEventTap] Health check found missing run loop source; rebuilding tap")
            rebuildEventTap(reason: "missing run loop source")
            return
        }

        if CGEvent.tapIsEnabled(tap: tap) {
            print("[KeyboardEventTap] Health check OK: tap enabled")
            return
        }

        print("[KeyboardEventTap] Health check found disabled tap; re-enabling")
        CGEvent.tapEnable(tap: tap, enable: true)

        if CGEvent.tapIsEnabled(tap: tap) {
            print("[KeyboardEventTap] Health check recovered disabled tap")
            return
        }

        print("[KeyboardEventTap] Re-enable failed; recreating event tap")
        rebuildEventTap(reason: reason)
    }

    func disable() {
        installRetryWorkItem?.cancel()
        installRetryWorkItem = nil
        healthTimer?.invalidate()
        healthTimer = nil
        healthTimerTarget = nil
        tearDownEventTap(reason: "disable")
        print("[KeyboardEventTap] Disabled")
    }

    private func tearDownEventTap(reason: String) {
        print("[KeyboardEventTap] Tearing down event tap reason=\(reason)")
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    func setSwitcherVisible(_ visible: Bool) {
        switcherVisible = visible
        if !visible {
            searchModeActive = false  // Reset search mode when switcher hides
            hadInteractionSinceActivation = false
            pendingActivation = false
            isHoldingQuit = false
            isHoldingE = false
            nativeCommandTabSessionActive = false
            activeActivationShortcut = nil
            showSwitcherTimer?.cancel()
            showSwitcherTimer = nil
        }
    }

    func setSearchModeActive(_ active: Bool) {
        searchModeActive = active
        print("[KeyboardEventTap] Search mode: \(active)")
    }

    func setActivationModifier(_ modifier: ModifierKey) {
        if modifier == .command && !isCommandTabHandlingEnabled {
            activationModifier = .option
            print("[KeyboardEventTap] Command+Tab handling is temporarily disabled; using Option+Tab fallback. Debug shortcut also active: \(debugActivationShortcut.name)")
            return
        }

        activationModifier = modifier
        print("[KeyboardEventTap] Activation modifier set to \(modifier.symbol); debug shortcut also active: \(debugActivationShortcut.name)")
    }

    private var configuredActivationShortcut: ActivationShortcut {
        ActivationShortcut(
            name: "\(activationModifier.symbol)+Tab",
            keyCode: activationKeyCode,
            modifiers: [activationModifier],
            usesShiftForReverse: true,
            showsImmediately: false
        )
    }

    private func matchingActivationShortcut(for keyCode: UInt16) -> ActivationShortcut? {
        if keyCode == debugActivationShortcut.keyCode,
           modifierTracker.contains(debugActivationShortcut.modifiers) {
            return debugActivationShortcut
        }

        let configuredShortcut = configuredActivationShortcut
        if keyCode == configuredShortcut.keyCode,
           modifierTracker.contains(configuredShortcut.modifiers) {
            if configuredShortcut.modifiers.contains(.command) && !isCommandTabHandlingEnabled {
                return nil
            }
            return configuredShortcut
        }

        return nil
    }

    private func activeShortcutMatches(keyCode: UInt16) -> ActivationShortcut? {
        if let activeActivationShortcut,
           keyCode == activeActivationShortcut.keyCode,
           modifierTracker.contains(activeActivationShortcut.modifiers) {
            return activeActivationShortcut
        }

        return matchingActivationShortcut(for: keyCode)
    }

    private func wasActiveActivationModifierReleased(oldFlags: CGEventFlags, newFlags: CGEventFlags) -> Bool {
        guard let shortcut = activeActivationShortcut else { return false }
        return shortcut.modifiers.contains { modifier in
            modifierTracker.wasModifierReleased(oldFlags: oldFlags, newFlags: newFlags, modifier: modifier)
        }
    }

    private func createEventTap(reason: String) -> Bool {
        logStartupDiagnostics(context: "pre-create \(reason)")
        print("[KeyboardEventTap] Creating CGEventTap reason=\(reason) tap=.cgSessionEventTap place=.headInsertEventTap options=.defaultTap")

        // Events to monitor: key down, key up, flags changed (modifiers)
        let eventMask: CGEventMask = (
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        )
        print("[KeyboardEventTap] Event mask=\(eventMask)")

        // Store self reference for callback
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, userInfo in
                print("[KeyboardEventTap] Callback invoked type=\(type.rawValue)")
                guard let userInfo = userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let eventTap = Unmanaged<KeyboardEventTap>.fromOpaque(userInfo).takeUnretainedValue()
                return eventTap.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: userInfo
        ) else {
            print("[KeyboardEventTap] CGEventTap creation FAILED. AXTrusted=\(AXIsProcessTrusted()) inputMonitoring=\(CGPreflightListenEventAccess())")
            return false
        }
        print("[KeyboardEventTap] CGEventTap creation succeeded")

        eventTap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            print("[KeyboardEventTap] CFMachPortCreateRunLoopSource FAILED")
            eventTap = nil
            return false
        }

        runLoopSource = source
        print("[KeyboardEventTap] RunLoop source created; adding to main run loop common modes")
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[KeyboardEventTap] CGEventTap enabled")

        logTapState(context: "post-create \(reason)")
        print("[KeyboardEventTap] Successfully created and enabled; test shortcut: \(debugActivationShortcut.name)")
        return true
    }

    private func rebuildEventTap(reason: String) {
        tearDownEventTap(reason: "rebuild \(reason)")
        _ = createEventTap(reason: "rebuild \(reason)")
    }

    private func scheduleRetry(afterFailureReason reason: String) {
        guard installRetryCount < maxInstallRetryCount else {
            print("[KeyboardEventTap] Install retry limit reached after reason=\(reason)")
            return
        }

        installRetryCount += 1
        let delay = min(5.0, Double(installRetryCount))
        print("[KeyboardEventTap] Scheduling retry #\(installRetryCount) in \(String(format: "%.1f", delay))s after failure reason=\(reason)")
        scheduleInstall(reason: "retry #\(installRetryCount) after \(reason)", delay: delay)
    }

    private func startHealthMonitoring() {
        guard healthTimer == nil else { return }
        print("[KeyboardEventTap] Starting health monitor interval=\(healthCheckInterval)s")

        let target = KeyboardEventTapHealthTarget(eventTap: self)
        healthTimerTarget = target
        let timer = Timer(
            timeInterval: healthCheckInterval,
            target: target,
            selector: #selector(KeyboardEventTapHealthTarget.healthTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
        healthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func logTapState(context: String) {
        if let tap = eventTap {
            print("[KeyboardEventTap][\(context)] tapExists=true tapEnabled=\(CGEvent.tapIsEnabled(tap: tap)) runLoopSourceExists=\(runLoopSource != nil)")
        } else {
            print("[KeyboardEventTap][\(context)] tapExists=false tapEnabled=false runLoopSourceExists=\(runLoopSource != nil)")
        }
    }

    private func isSystemCommandTabKeyEvent(type: CGEventType, keyCode: UInt16, flags: CGEventFlags) -> Bool {
        (type == .keyDown || type == .keyUp)
            && keyCode == activationKeyCode
            && flags.contains(.maskCommand)
    }

    private func observeSystemCommandTabEvent(type: CGEventType, keyCode: UInt16, flags: CGEventFlags) {
        guard type == .keyDown, keyCode == activationKeyCode, flags.contains(.maskCommand) else { return }

        if nativeCommandTabSessionActive {
            if flags.contains(.maskShift) {
                print("[KeyboardEventTap] Observed native Cmd+Shift+Tab cycle")
                onShortcutTriggered.send(.nativeSwitchCyclePrevious)
            } else {
                print("[KeyboardEventTap] Observed native Cmd+Tab cycle")
                onShortcutTriggered.send(.nativeSwitchCycleNext)
            }
        } else {
            nativeCommandTabSessionActive = true
            print("[KeyboardEventTap] Observed native Cmd+Tab session start")
            onShortcutTriggered.send(.nativeSwitchStarted)
        }
    }

    private func logKeyboardEvent(type: CGEventType, keyCode: UInt16, flags: CGEventFlags, isRepeat: Bool) {
        guard isKeyboardDebugLoggingEnabled else { return }

        let typeName: String
        switch type {
        case .keyDown:
            typeName = "keyDown"
        case .keyUp:
            typeName = "keyUp"
        case .flagsChanged:
            typeName = "flagsChanged"
        default:
            typeName = "event(\(type.rawValue))"
        }

        print("[KeyboardEventTap][debug] Received key event \(typeName) key=\(keyName(for: keyCode)) code=\(keyCode) flags=\(modifierDescription(from: flags)) tracker=\(modifierDescription(from: modifierTracker.currentModifierSet())) repeat=\(isRepeat)")
    }

    private func keyName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Tab:
            return "Tab"
        case kVK_Space:
            return "Space"
        case kVK_ANSI_Grave:
            return "Grave"
        case kVK_Return:
            return "Return"
        case kVK_Escape:
            return "Escape"
        case kVK_LeftArrow:
            return "LeftArrow"
        case kVK_RightArrow:
            return "RightArrow"
        case kVK_UpArrow:
            return "UpArrow"
        case kVK_DownArrow:
            return "DownArrow"
        default:
            return "Unknown"
        }
    }

    private func modifierDescription(from flags: CGEventFlags) -> String {
        modifierDescription(from: ModifierKey.allCases.filter { flags.contains($0.cgFlag) })
    }

    private func modifierDescription(from modifiers: some Sequence<ModifierKey>) -> String {
        let symbols = modifiers.map(\.symbol).joined()
        return symbols.isEmpty ? "none" : symbols
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Handle tap disabled events
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let reason = type == .tapDisabledByTimeout ? "tapDisabledByTimeout" : "tapDisabledByUserInput"
            print("[KeyboardEventTap] \(reason) received; re-enabling tap")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                print("[KeyboardEventTap] Re-enable requested; enabled=\(CGEvent.tapIsEnabled(tap: tap))")
            } else {
                print("[KeyboardEventTap] Disable event received but eventTap is nil; rebuilding")
                scheduleInstall(reason: reason, delay: 0.2)
            }
            return Unmanaged.passUnretained(event)
        }

        callbackCount += 1
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if type != .flagsChanged {
            logKeyboardEvent(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
        }

        if isSystemCommandTabKeyEvent(type: type, keyCode: keyCode, flags: flags) {
            observeSystemCommandTabEvent(type: type, keyCode: keyCode, flags: flags)
            if activeActivationShortcut?.modifiers.contains(.command) == true {
                showSwitcherTimer?.cancel()
                showSwitcherTimer = nil
                pendingActivation = false
                activeActivationShortcut = nil
            }
            return Unmanaged.passUnretained(event)
        }

        // Handle modifier changes
        if type == .flagsChanged {
            let oldFlags = previousFlags
            previousFlags = flags
            modifierTracker.update(flags: flags)
            logKeyboardEvent(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat)

            if nativeCommandTabSessionActive,
               modifierTracker.wasModifierReleased(oldFlags: oldFlags, newFlags: flags, modifier: .command) {
                nativeCommandTabSessionActive = false
                print("[KeyboardEventTap] Observed native Cmd+Tab session end")
                onShortcutTriggered.send(.nativeSwitchEnded)
                return Unmanaged.passUnretained(event)
            }

            // Check if the active activation shortcut was released
            if wasActiveActivationModifierReleased(oldFlags: oldFlags, newFlags: flags) {
                let elapsed = CFAbsoluteTimeGetCurrent() - activationTime

                // Cancel the show timer if pending
                showSwitcherTimer?.cancel()
                showSwitcherTimer = nil

                // Quick switch: released before timer fired (UI never shown)
                if pendingActivation && !hadInteractionSinceActivation {
                    pendingActivation = false
                    activeActivationShortcut = nil
                    print("[KeyboardEventTap] Quick switch detected (\(Int(elapsed * 1000))ms)")
                    onShortcutTriggered.send(.quickSwitch)
                    return nil
                }

                // Normal release while switcher visible (not in search mode)
                if switcherVisible && !searchModeActive {
                    pendingActivation = false
                    activeActivationShortcut = nil
                    print("[KeyboardEventTap] Modifier released, confirming selection")
                    onShortcutTriggered.send(.confirm)
                    return nil
                }

                pendingActivation = false
                activeActivationShortcut = nil
            }

            return Unmanaged.passUnretained(event)
        }

        // Handle key-up events
        if type == .keyUp {
            if keyCode == UInt16(kVK_ANSI_Q) && isHoldingQuit {
                isHoldingQuit = false
                print("[KeyboardEventTap] Q released, cancel quit hold")
                onShortcutTriggered.send(.quitHoldCancelled)
                return nil
            }
            if keyCode == UInt16(kVK_ANSI_E) && isHoldingE {
                let holdDuration = CFAbsoluteTimeGetCurrent() - eKeyDownTime
                isHoldingE = false
                if holdDuration < eHoldThreshold {
                    // Short tap → toggle resource monitor
                    print("[KeyboardEventTap] E tapped (\(Int(holdDuration * 1000))ms), toggle monitor")
                    onShortcutTriggered.send(.toggleResourceMonitor)
                } else {
                    // Long hold → AI insight requested
                    print("[KeyboardEventTap] E held (\(Int(holdDuration * 1000))ms), AI insight")
                    onShortcutTriggered.send(.aiInsightRequested)
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        // Only handle key down events for shortcuts
        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        // Handle shortcuts while switcher is visible OR pending (check this FIRST)
        if switcherVisible || pendingActivation {
            // Activation key = cycle through apps while holding the active shortcut modifiers.
            // If pending, this cancels quick-switch and shows the panel.
            if let shortcut = activeShortcutMatches(keyCode: keyCode) {
                hadInteractionSinceActivation = true

                // If still pending, cancel timer and show panel now
                if pendingActivation {
                    showSwitcherTimer?.cancel()
                    showSwitcherTimer = nil
                    pendingActivation = false
                    switcherVisible = true
                    print("[KeyboardEventTap] Second activation key pressed (\(shortcut.name)), showing switcher immediately")
                    onShortcutTriggered.send(.showSwitcher)
                    // Don't cycle yet - first show, next activation key will cycle
                    return nil
                }

                if shortcut.usesShiftForReverse && modifierTracker.isShiftPressed {
                    print("[KeyboardEventTap] Cycle previous")
                    onShortcutTriggered.send(.cyclePrevious)
                } else {
                    print("[KeyboardEventTap] Cycle next")
                    onShortcutTriggered.send(.cycleNext)
                }
                return nil
            }

            // Backtick (`) = cycle windows within app (with or without modifier held)
            if keyCode == UInt16(kVK_ANSI_Grave) {
                hadInteractionSinceActivation = true
                if modifierTracker.isShiftPressed {
                    print("[KeyboardEventTap] Cycle window previous")
                    onShortcutTriggered.send(.cycleWindowPrevious)
                } else {
                    print("[KeyboardEventTap] Cycle window next")
                    onShortcutTriggered.send(.cycleWindowNext)
                }
                return nil
            }

            // Q = hold to quit selected app (only when not in search mode)
            if !searchModeActive {
                if keyCode == UInt16(kVK_ANSI_Q) {
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                    if isRepeat {
                        return nil
                    }
                    if !isHoldingQuit {
                        isHoldingQuit = true
                        hadInteractionSinceActivation = true
                        print("[KeyboardEventTap] Q pressed, start quit hold")
                        onShortcutTriggered.send(.quitHoldStarted)
                    }
                    return nil
                }

                // E = tap to toggle monitor, hold for AI insight
                if keyCode == UInt16(kVK_ANSI_E) {
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                    if isRepeat { return nil }
                    if !isHoldingE {
                        isHoldingE = true
                        eKeyDownTime = CFAbsoluteTimeGetCurrent()
                        hadInteractionSinceActivation = true
                        // Send hold-started so UI can show charging animation
                        onShortcutTriggered.send(.eHoldStarted)
                    }
                    return nil
                }

                // F = toggle process grouping in resource monitor
                if keyCode == UInt16(kVK_ANSI_F) {
                    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                    if isRepeat { return nil }
                    hadInteractionSinceActivation = true
                    onShortcutTriggered.send(.toggleProcessGrouping)
                    return nil
                }
            }

            // Enter = activate search OR confirm selection (in search mode)
            if keyCode == UInt16(kVK_Return) {
                hadInteractionSinceActivation = true
                if searchModeActive {
                    print("[KeyboardEventTap] Confirm search selection")
                    onShortcutTriggered.send(.confirm)
                } else {
                    print("[KeyboardEventTap] Activate search")
                    onShortcutTriggered.send(.activateSearch)
                }
                return nil
            }

            // Escape = dismiss
            if keyCode == UInt16(kVK_Escape) {
                print("[KeyboardEventTap] Dismiss")
                onShortcutTriggered.send(.dismiss)
                return nil
            }

            // Arrow keys for navigation (WSAD only in normal mode so user can type in search)
            if searchModeActive {
                // In search mode: only arrow keys navigate results (WSAD passed through for typing)
                if keyCode == UInt16(kVK_UpArrow) || keyCode == UInt16(kVK_LeftArrow) {
                    hadInteractionSinceActivation = true
                    print("[KeyboardEventTap] Navigate up (search)")
                    onShortcutTriggered.send(.navigateUp)
                    return nil
                }

                if keyCode == UInt16(kVK_DownArrow) || keyCode == UInt16(kVK_RightArrow) {
                    hadInteractionSinceActivation = true
                    print("[KeyboardEventTap] Navigate down (search)")
                    onShortcutTriggered.send(.navigateDown)
                    return nil
                }

                // TAB in search mode = navigate down (like down arrow)
                if keyCode == activationKeyCode {
                    hadInteractionSinceActivation = true
                    if modifierTracker.isShiftPressed {
                        print("[KeyboardEventTap] Tab+Shift in search = navigate up")
                        onShortcutTriggered.send(.navigateUp)
                    } else {
                        print("[KeyboardEventTap] Tab in search = navigate down")
                        onShortcutTriggered.send(.navigateDown)
                    }
                    return nil
                }
            } else {
                // In normal mode: arrows and WSAD navigate the spatial workspace.
                // Left/Right (A/D) = cycle through apps (linear)
                if keyCode == UInt16(kVK_LeftArrow) || keyCode == UInt16(kVK_ANSI_A) {
                    hadInteractionSinceActivation = true
                    print("[KeyboardEventTap] Left/A = previous app")
                    onShortcutTriggered.send(.cyclePrevious)
                    return nil
                }

                if keyCode == UInt16(kVK_RightArrow) || keyCode == UInt16(kVK_ANSI_D) {
                    hadInteractionSinceActivation = true
                    print("[KeyboardEventTap] Right/D = next app")
                    onShortcutTriggered.send(.cycleNext)
                    return nil
                }

                // Up/Down (W/S) = cycle windows in the selected app.
                if keyCode == UInt16(kVK_UpArrow) || keyCode == UInt16(kVK_ANSI_W) {
                    hadInteractionSinceActivation = true
                    print("[KeyboardEventTap] Up/W = previous window")
                    onShortcutTriggered.send(.navigateRowUp)
                    return nil
                }

                if keyCode == UInt16(kVK_DownArrow) || keyCode == UInt16(kVK_ANSI_S) {
                    hadInteractionSinceActivation = true
                    print("[KeyboardEventTap] Down/S = next window")
                    onShortcutTriggered.send(.navigateRowDown)
                    return nil
                }
            }

            // Pass through other keys
            return Unmanaged.passUnretained(event)
        }

        // Check for activation shortcut only when switcher is not visible.
        if let shortcut = matchingActivationShortcut(for: keyCode), !pendingActivation {
            print("[KeyboardEventTap] Activation started via \(shortcut.name) (switcherVisible=\(switcherVisible))")
            activationTime = CFAbsoluteTimeGetCurrent()
            hadInteractionSinceActivation = false
            pendingActivation = true
            activeActivationShortcut = shortcut

            // Notify that activation started (for pre-caching)
            onShortcutTriggered.send(.activationStarted)

            // The temporary diagnostic shortcut should prove the event path immediately.
            showSwitcherTimer?.cancel()
            if shortcut.showsImmediately {
                pendingActivation = false
                switcherVisible = true
                activeActivationShortcut = nil
                print("[KeyboardEventTap] Showing switcher immediately via \(shortcut.name)")
                onShortcutTriggered.send(.showSwitcher)
                return nil
            }

            // Start timer to show switcher if not released quickly
            let timer = DispatchWorkItem { [weak self] in
                guard let self = self, self.pendingActivation else { return }
                self.pendingActivation = false
                self.switcherVisible = true
                print("[KeyboardEventTap] Timer fired, showing switcher via \(self.activeActivationShortcut?.name ?? "unknown shortcut")")
                self.onShortcutTriggered.send(.showSwitcher)
            }
            showSwitcherTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + quickSwitchThreshold, execute: timer)

            return nil
        }

        return Unmanaged.passUnretained(event)
    }
}
