import CoreGraphics
import AppKit
import ApplicationServices

final class WindowEnumerator {
    private let isEnumerationDebugLoggingEnabled = false
    private var hasLoggedMissingAccessibility = false

    struct EnumerationOptions {
        var includeMinimized: Bool = true
        var includeAllSpaces: Bool = true
        var hydratePreviewImages: Bool = false
        var minimumWidth: CGFloat = 50
        var minimumHeight: CGFloat = 50

        static let `default` = EnumerationOptions()
    }

    // Bundle IDs to skip
    private let skipBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.WindowManager",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.SystemUIServer"
    ]

    /// Enumerate windows using Accessibility API as the primary source
    /// This is more reliable for window switching since we use AX to raise windows
    func enumerateGroupedByApp(options: EnumerationOptions = .default) -> [ApplicationModel] {
        guard AXIsProcessTrusted() else {
            if !hasLoggedMissingAccessibility {
                print("[WindowEnumerator] Skipping window enumeration: Accessibility is not granted")
                hasLoggedMissingAccessibility = true
            }
            return []
        }

        let excludedBundleIDs = Set(UserPreferences.load().excludedBundleIDs)
        let currentSpaceWindowIDs = Self.currentSpaceWindowIDs()

        // Get all running apps with regular activation policy (visible in Dock)
        let runningApps = NSWorkspace.shared.runningApplications.filter { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return app.activationPolicy == .regular
                && !skipBundleIDs.contains(bundleID)
                && !excludedBundleIDs.contains(bundleID)
        }

        var applications: [ApplicationModel] = []

        for app in runningApps {
            guard let name = app.localizedName,
                  let bundleIdentifier = app.bundleIdentifier else {
                continue
            }

            let pid = app.processIdentifier
            // processIdentifier returns -1 if the app has already terminated
            guard pid >= 0 else { continue }
            let axApp = AXUIElementCreateApplication(pid)

            // Get windows from Accessibility API
            var windowsRef: CFTypeRef?
            let axResult = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)

            // If AX fails or returns empty, include the app with a synthetic window
            // This handles apps like Steam/games that may not fully support Accessibility
            let axWindows = (axResult == .success) ? (windowsRef as? [AXUIElement]) ?? [] : []

            if axResult != .success {
                print("[WindowEnumerator] AX failed for \(name) (error: \(axResult.rawValue)), using synthetic window")
            } else if axWindows.isEmpty {
                print("[WindowEnumerator] AX returned empty windows for \(name), using synthetic window")
            }

            var windows: [WindowInfo] = []
            var rejectedWindows: [String] = []

            for (axIndex, axWindow) in axWindows.enumerated() {
                // Get window ID
                var windowID: CGWindowID = 0
                let idResult = _AXUIElementGetWindow(axWindow, &windowID)

                // Get title
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
                let title = titleRef as? String

                // Get position and size
                var positionRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef)
                AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)

                var position = CGPoint.zero
                var size = CGSize.zero

                if let posValue = positionRef {
                    AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
                }
                if let sizeValue = sizeRef {
                    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
                }

                // Check if minimized
                var minimizedRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimizedRef)
                let isMinimized = (minimizedRef as? Bool) ?? false

                if isMinimized && !options.includeMinimized {
                    rejectedWindows.append("#\(axIndex) minimized hidden title=\(title ?? "untitled")")
                    continue
                }

                // Skip tiny live windows only for current-Space workspace views. All-Spaces
                // enumeration can receive temporarily collapsed off-Space geometry.
                if !isMinimized,
                   !options.includeAllSpaces,
                   (size.width < options.minimumWidth || size.height < options.minimumHeight) {
                    rejectedWindows.append("#\(axIndex) tiny title=\(title ?? "untitled") size=\(Int(size.width))x\(Int(size.height))")
                    continue
                }

                // Get subrole to filter out non-standard windows
                var subroleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &subroleRef)
                let subrole = subroleRef as? String

                // Skip known non-window subroles (like system overlays)
                // Be permissive - allow windows with no subrole or unknown subroles
                if let subrole = subrole {
                    let invalidSubroles = ["AXSystemDialog", "AXSheet", "AXDrawer", "AXUnknown"]
                    if invalidSubroles.contains(subrole) {
                        rejectedWindows.append("#\(axIndex) subrole=\(subrole) title=\(title ?? "untitled")")
                        continue
                    }
                }

                // Use a valid window ID, or generate a unique one based on index
                let finalWindowID: CGWindowID
                let hasReliableWindowID: Bool
                if idResult == .success && windowID != 0 {
                    finalWindowID = windowID
                    hasReliableWindowID = true
                } else {
                    finalWindowID = PreviewIdentity.pseudoWindowID(
                        ownerPID: pid,
                        axIndex: axIndex,
                        title: title ?? name,
                        bounds: CGRect(origin: position, size: size)
                    )
                    hasReliableWindowID = false
                    print("[WindowEnumerator][preview] missing AX CGWindowID for \(name) title=\(title ?? "untitled") axResult=\(idResult.rawValue); using pseudoID=\(finalWindowID)")
                }

                let isOnCurrentSpace = hasReliableWindowID
                    ? currentSpaceWindowIDs?.contains(finalWindowID) ?? true
                    : options.includeAllSpaces
                if !options.includeAllSpaces && !isMinimized && !isOnCurrentSpace {
                    rejectedWindows.append("#\(axIndex) off-space title=\(title ?? "untitled") id=\(finalWindowID)")
                    continue
                }

                windows.append(WindowInfo(
                    windowID: finalWindowID,
                    ownerPID: pid,
                    ownerBundleIdentifier: bundleIdentifier,
                    axIndex: axIndex,
                    ownerName: name,
                    windowName: title,
                    bounds: CGRect(origin: position, size: size),
                    isOnScreen: !isMinimized && isOnCurrentSpace,
                    isMinimized: isMinimized,
                    spaceID: nil,
                    hasReliableWindowID: hasReliableWindowID
                ))
            }

            let icon = app.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()

            // If no windows found through AX, create a synthetic window
            // This ensures apps like Steam/games still appear in the switcher
            if windows.isEmpty && axWindows.isEmpty {
                let syntheticWindow = WindowInfo(
                    windowID: CGWindowID(pid),
                    ownerPID: pid,
                    ownerBundleIdentifier: bundleIdentifier,
                    axIndex: nil,
                    ownerName: name,
                    windowName: name,  // Use app name as window title
                    bounds: .zero,
                    isOnScreen: true,
                    isMinimized: false,
                    spaceID: nil,
                    hasReliableWindowID: false
                )
                windows.append(syntheticWindow)
            }

            guard !windows.isEmpty else {
                continue
            }

            applications.append(ApplicationModel(
                pid: pid,
                bundleIdentifier: bundleIdentifier,
                name: name,
                icon: icon,
                windows: windows.map { info in
                    let previewIdentity = PreviewIdentity(
                        ownerPID: info.ownerPID,
                        bundleIdentifier: info.ownerBundleIdentifier,
                        cgWindowID: info.windowID,
                        axIndex: info.axIndex,
                        title: info.windowName ?? info.ownerName,
                        bounds: info.bounds,
                        hasReliableCGWindowID: info.hasReliableWindowID
                    )
                    return WindowModel(
                        from: info,
                        previewImage: options.hydratePreviewImages
                            ? WindowPreviewService.shared.cachedPreview(for: previewIdentity)
                            : nil
                    )
                },
                isActive: app.isActive
            ))

            logInventory(
                appName: name,
                axWindowCount: axWindows.count,
                acceptedWindows: windows,
                rejectedWindows: rejectedWindows
            )
        }

        // Sort: active app first, then alphabetically by name
        return applications.sorted { app1, app2 in
            if app1.isActive && !app2.isActive { return true }
            if !app1.isActive && app2.isActive { return false }
            return app1.name.localizedCaseInsensitiveCompare(app2.name) == .orderedAscending
        }
    }

    private static func currentSpaceWindowIDs() -> Set<CGWindowID>? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        return Set(windowList.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? NSNumber else {
                return nil
            }
            return CGWindowID(number.uint32Value)
        })
    }

    private func logInventory(
        appName: String,
        axWindowCount: Int,
        acceptedWindows: [WindowInfo],
        rejectedWindows: [String]
    ) {
        guard isEnumerationDebugLoggingEnabled else { return }

        let accepted = acceptedWindows
            .map { "#\($0.axIndex.map(String.init) ?? "-") id=\($0.windowID) reliable=\($0.hasReliableWindowID) minimized=\($0.isMinimized) onScreen=\($0.isOnScreen) title=\($0.windowName ?? "untitled")" }
            .joined(separator: " | ")
        let rejected = rejectedWindows.isEmpty ? "none" : rejectedWindows.joined(separator: " | ")
        print("[WindowEnumerator][debug] \(appName): AX=\(axWindowCount) accepted=\(acceptedWindows.count) windows=\(accepted.isEmpty ? "none" : accepted) rejected=\(rejected)")
    }
}
