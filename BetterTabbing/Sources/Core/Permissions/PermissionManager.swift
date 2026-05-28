import CoreGraphics
import AppKit
import ApplicationServices

actor PermissionManager {
    static let shared = PermissionManager()

    private var hasRequestedScreenRecordingThisLaunch = false

    enum Permission: String, CaseIterable {
        case inputMonitoring = "Input Monitoring"
        case accessibility = "Accessibility"
        case screenRecording = "Screen Recording"
    }

    struct Status {
        var inputMonitoring: Bool
        var accessibility: Bool
        var screenRecording: Bool

        var allGranted: Bool {
            inputMonitoring && accessibility && screenRecording
        }

        var description: String {
            """
            Input Monitoring: \(inputMonitoring ? "✓" : "✗")
            Accessibility: \(accessibility ? "✓" : "✗")
            Screen Recording: \(screenRecording ? "✓" : "✗")
            """
        }
    }

    func checkStatus() -> Status {
        Status(
            inputMonitoring: checkInputMonitoring(),
            accessibility: checkAccessibility(),
            screenRecording: checkScreenRecording()
        )
    }

    func requestPermissions() async {
        let status = checkStatus()

        if !status.inputMonitoring {
            requestInputMonitoring()
        }

        if !status.accessibility {
            requestAccessibility()
        }

        if !status.screenRecording {
            print("[PermissionManager] Screen Recording will be requested when window previews are first used")
        }
    }

    // MARK: - Input Monitoring

    private func checkInputMonitoring() -> Bool {
        return CGPreflightListenEventAccess()
    }

    private func requestInputMonitoring() {
        let granted = CGRequestListenEventAccess()
        print("[PermissionManager] Input Monitoring request result: \(granted)")
    }

    // MARK: - Accessibility

    private func checkAccessibility() -> Bool {
        return AXIsProcessTrusted()
    }

    private func requestAccessibility() {
        // Create the prompt key string directly to avoid Swift 6 concurrency issues
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        let _ = AXIsProcessTrustedWithOptions(options)
        print("[PermissionManager] Accessibility permission requested")
    }

    // MARK: - Screen Recording

    private func checkScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestScreenRecordingIfNeeded() async -> Bool {
        if checkScreenRecording() {
            return true
        }

        guard !hasRequestedScreenRecordingThisLaunch else {
            return false
        }

        hasRequestedScreenRecordingThisLaunch = true
        let granted = await MainActor.run {
            CGRequestScreenCaptureAccess()
        }

        print("[PermissionManager] Screen Recording request result: \(granted)")
        return granted || checkScreenRecording()
    }

    // MARK: - Open System Preferences

    func openSystemPreferences(for permission: Permission) {
        let urlString: String
        switch permission {
        case .inputMonitoring:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
