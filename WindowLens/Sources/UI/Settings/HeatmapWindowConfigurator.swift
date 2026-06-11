import AppKit
import SwiftUI

enum HeatmapWindowConfigurator {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("WindowLensHeatmapWindow")

    @MainActor
    static func configure(_ window: NSWindow) {
        window.identifier = windowIdentifier
        window.title = "Usage Heatmap"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .automatic
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 520)
    }

    @MainActor
    static func closeWindow() {
        NSApp.windows.first { $0.identifier == windowIdentifier }?.performClose(nil)
    }
}
