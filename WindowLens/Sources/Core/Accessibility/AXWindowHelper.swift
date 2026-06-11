import ApplicationServices
import AppKit

/// Helper for fetching window information via Accessibility API
/// This works with Accessibility permission (doesn't require Screen Recording)
final class AXWindowHelper {

    /// Struct containing both title and the AX element for later use
    struct WindowInfo {
        let title: String
        let axElement: AXUIElement
    }

    struct FocusedWindowSnapshot {
        let windowID: CGWindowID
        let title: String
        let bounds: CGRect
        let hasReliableWindowID: Bool
    }

    static func focusedWindowSnapshot(for pid: pid_t) -> FocusedWindowSnapshot? {
        let axApp = AXUIElementCreateApplication(pid)
        let focusedWindow = copyWindowAttribute(kAXFocusedWindowAttribute, from: axApp)
            ?? copyWindowAttribute(kAXMainWindowAttribute, from: axApp)
        guard let focusedWindow else { return nil }

        var windowID: CGWindowID = 0
        let idResult = _AXUIElementGetWindow(focusedWindow, &windowID)
        let hasReliableWindowID = idResult == .success && windowID != 0

        return FocusedWindowSnapshot(
            windowID: windowID,
            title: getWindowTitle(for: focusedWindow) ?? "",
            bounds: getWindowBounds(for: focusedWindow),
            hasReliableWindowID: hasReliableWindowID
        )
    }

    /// Get window titles for a given process ID using Accessibility API
    /// Returns both titles mapped by CGWindowID and a list of AX elements for windows we couldn't map
    static func getWindowTitles(for pid: pid_t) -> [CGWindowID: String] {
        var result: [CGWindowID: String] = [:]

        let axApp = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)

        guard windowsResult == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return result
        }

        for axWindow in windows {
            // Get window title using multiple strategies
            let title = getWindowTitle(for: axWindow)
            guard let title = title, !title.isEmpty else {
                continue
            }

            // Try to get the CGWindowID for this AXUIElement
            var windowID: CGWindowID = 0
            let idResult = _AXUIElementGetWindow(axWindow, &windowID)

            if idResult == .success && windowID != 0 {
                result[windowID] = title
            }
        }

        return result
    }

    /// Get the best available title for a window using multiple strategies
    private static func getWindowTitle(for axWindow: AXUIElement) -> String? {
        // Strategy 1: Standard title attribute
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String, !title.isEmpty {
            return title
        }

        // Strategy 2: Document attribute (file path)
        var docRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXDocumentAttribute as CFString, &docRef) == .success,
           let docPath = docRef as? String, !docPath.isEmpty {
            return (docPath as NSString).lastPathComponent
        }

        // Strategy 3: Description attribute
        var descRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXDescriptionAttribute as CFString, &descRef) == .success,
           let desc = descRef as? String, !desc.isEmpty {
            return desc
        }

        // Strategy 4: Role description
        var roleDescRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXRoleDescriptionAttribute as CFString, &roleDescRef) == .success,
           let roleDesc = roleDescRef as? String, !roleDesc.isEmpty {
            return roleDesc
        }

        return nil
    }

    private static func copyWindowAttribute(_ attribute: String, from axApp: AXUIElement) -> AXUIElement? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, attribute as CFString, &valueRef) == .success else {
            return nil
        }
        return valueRef as! AXUIElement?
    }

    private static func getWindowBounds(for axWindow: AXUIElement) -> CGRect {
        var position = CGPoint.zero
        var size = CGSize.zero

        var positionRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef) == .success,
           let positionRef {
            let positionValue = positionRef as! AXValue
            if AXValueGetType(positionValue) == .cgPoint {
                AXValueGetValue(positionValue, .cgPoint, &position)
            }
        }

        var sizeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let sizeRef {
            let sizeValue = sizeRef as! AXValue
            if AXValueGetType(sizeValue) == .cgSize {
                AXValueGetValue(sizeValue, .cgSize, &size)
            }
        }

        return CGRect(origin: position, size: size)
    }

    /// Get the AXUIElement for a specific window by CGWindowID
    static func getAXWindow(for windowID: CGWindowID, pid: pid_t) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }

        for axWindow in windows {
            var axWindowID: CGWindowID = 0
            if _AXUIElementGetWindow(axWindow, &axWindowID) == .success && axWindowID == windowID {
                return axWindow
            }
        }

        return nil
    }

    /// Get all AX windows for a PID, ordered by position (for fallback matching)
    static func getOrderedAXWindows(for pid: pid_t) -> [AXUIElement] {
        let axApp = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return []
        }

        return windows
    }

    /// Get window titles only for specific PIDs - runs in PARALLEL for speed
    static func getWindowTitles(for pids: Set<pid_t>) -> [CGWindowID: String] {
        // Check if we have accessibility permission first
        guard AXIsProcessTrusted() else {
            return [:]
        }

        // For small number of PIDs, just do it serially (overhead not worth it)
        if pids.count <= 3 {
            var allTitles: [CGWindowID: String] = [:]
            for pid in pids {
                let titles = getWindowTitles(for: pid)
                allTitles.merge(titles) { _, new in new }
            }
            return allTitles
        }

        // For larger counts, run in parallel
        final class TitleAccumulator: @unchecked Sendable {
            private let lock = NSLock()
            private var titles: [CGWindowID: String] = [:]

            func merge(_ newTitles: [CGWindowID: String]) {
                lock.lock()
                titles.merge(newTitles) { _, new in new }
                lock.unlock()
            }

            func result() -> [CGWindowID: String] {
                lock.lock()
                defer { lock.unlock() }
                return titles
            }
        }

        let accumulator = TitleAccumulator()
        let pidList = Array(pids)

        DispatchQueue.concurrentPerform(iterations: pidList.count) { index in
            let pid = pidList[index]
            let titles = getWindowTitles(for: pid)

            accumulator.merge(titles)
        }

        return accumulator.result()
    }

    /// Closes a window using standard macOS AX actions (works for native and most Electron apps like Slack).
    static func closeWindow(_ axWindow: AXUIElement, pid: pid_t, windowID: CGWindowID = 0) -> Bool {
        prepareAutomationAccess(pid: pid)

        let targetWindow = (windowID != 0 ? getAXWindow(for: windowID, pid: pid) : nil) ?? axWindow
        clearFullscreenIfNeeded(targetWindow)
        unminimizeIfNeeded(targetWindow)

        let performedClose =
            AXUIElementPerformAction(targetWindow, "AXClose" as CFString) == .success
            || pressAttributedCloseButton(on: targetWindow)
            || pressCloseButtonBoundedOnWindow(targetWindow)

        guard performedClose else { return false }

        if windowID != 0 {
            // AXClose can report success while a minimized/hidden window stays in the window list.
            usleep(80_000)
            return getAXWindow(for: windowID, pid: pid) == nil
        }
        return true
    }

    private static func pressCloseButtonBoundedOnWindow(_ window: AXUIElement) -> Bool {
        var nodeBudget = 48
        return pressCloseButtonBounded(in: window, maxDepth: 4, remainingNodes: &nodeBudget)
    }

    private static func unminimizeIfNeeded(_ axWindow: AXUIElement) {
        guard isMinimized(axWindow) else { return }
        _ = AXUIElementSetAttributeValue(
            axWindow,
            kAXMinimizedAttribute as CFString,
            false as CFTypeRef
        )
        usleep(40_000)
    }

    private static func isMinimized(_ axWindow: AXUIElement) -> Bool {
        var minimizedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimizedRef) == .success else {
            return false
        }
        return (minimizedRef as? Bool) == true
    }

    /// Electron/Chromium apps (Slack, VS Code, etc.) may hide title-bar controls until this is set.
    private static func prepareAutomationAccess(pid: pid_t) {
        let axApp = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, true as CFTypeRef)
        _ = AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, true as CFTypeRef)
    }

    private static func clearFullscreenIfNeeded(_ axWindow: AXUIElement) {
        let fullscreenAttribute = "AXFullScreen" as CFString
        var fullscreenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, fullscreenAttribute, &fullscreenRef) == .success,
              (fullscreenRef as? Bool) == true else {
            return
        }
        _ = AXUIElementSetAttributeValue(axWindow, fullscreenAttribute, false as CFTypeRef)
    }

    /// Uses `kAXCloseButtonAttribute` — the supported way to reach the red close button without walking the web view tree.
    private static func pressAttributedCloseButton(on window: AXUIElement) -> Bool {
        var closeButtonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButtonRef) == .success,
              let closeButton = closeButtonRef else {
            return false
        }
        let button = closeButton as! AXUIElement
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    private static func pressCloseButtonBounded(
        in element: AXUIElement,
        maxDepth: Int,
        remainingNodes: inout Int
    ) -> Bool {
        guard remainingNodes > 0 else { return false }
        remainingNodes -= 1

        if isCloseButton(element),
           AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            return true
        }

        guard maxDepth > 0, remainingNodes > 0 else { return false }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return false
        }

        for child in children {
            if pressCloseButtonBounded(in: child, maxDepth: maxDepth - 1, remainingNodes: &remainingNodes) {
                return true
            }
            if remainingNodes <= 0 { break }
        }
        return false
    }

    private static func isCloseButton(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String,
           role == "AXCloseButton" {
            return true
        }

        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String,
           subrole == kAXCloseButtonSubrole as String {
            return true
        }

        return false
    }
}

// Private API declaration for getting CGWindowID from AXUIElement
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError
