import AppKit
import SwiftUI

enum DeadWindowsWindowConfigurator {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("WindowLensDeadWindowsWindow")

    @MainActor
    static func configure(_ window: NSWindow) {
        window.identifier = windowIdentifier
        window.title = "Unused Windows"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .automatic
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 520)
    }

    @MainActor
    static func closeWindow() {
        NSApp.windows.first { $0.identifier == windowIdentifier }?.performClose(nil)
    }
}
