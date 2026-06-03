import AppKit
import SwiftUI

enum SettingsWindowConfigurator {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("WindowLensSettingsWindow")
    private static let toolbarIdentifier = NSToolbar.Identifier("WindowLensSettingsToolbar")

    @MainActor
    private static var toolbarDelegate: SettingsToolbarDelegate?

    @MainActor
    static func configure(_ window: NSWindow) {
        window.identifier = windowIdentifier
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .line
        window.isMovableByWindowBackground = true
        window.toolbarStyle = .unified
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 520)
        clearHostingRootBackground(in: window)
    }

    @MainActor
    static func applyPostLayoutChrome(to window: NSWindow) {
        configure(window)
        installTrackingToolbarIfNeeded(in: window)
        enableFullHeightSidebar(in: window)
    }

    @MainActor
    private static func clearHostingRootBackground(in window: NSWindow) {
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor

        guard let hostingView = window.contentViewController?.view else { return }
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    @MainActor
    private static func installTrackingToolbarIfNeeded(in window: NSWindow) {
        guard let splitView = findSplitView(in: window.contentView) else { return }

        if let delegate = toolbarDelegate {
            delegate.splitView = splitView
        } else {
            let delegate = SettingsToolbarDelegate(splitView: splitView)
            toolbarDelegate = delegate

            let toolbar = NSToolbar(identifier: toolbarIdentifier)
            toolbar.delegate = delegate
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            window.toolbar = toolbar
        }

        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .line
    }

    @MainActor
    private static func enableFullHeightSidebar(in window: NSWindow) {
        guard let splitViewController = findSplitViewController(in: window.contentView) else { return }
        guard let sidebarItem = splitViewController.splitViewItems.first else { return }
        sidebarItem.allowsFullHeightLayout = true
    }

    @MainActor
    private static func findSplitView(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        if let splitView = view as? NSSplitView {
            return splitView
        }
        for subview in view.subviews {
            if let splitView = findSplitView(in: subview) {
                return splitView
            }
        }
        return nil
    }

    @MainActor
    private static func findSplitViewController(in view: NSView?) -> NSSplitViewController? {
        var responder: NSResponder? = view
        while let current = responder {
            if let controller = current as? NSSplitViewController {
                return controller
            }
            responder = current.nextResponder
        }
        return nil
    }
}

private final class SettingsToolbarDelegate: NSObject, NSToolbarDelegate {
    weak var splitView: NSSplitView?

    init(splitView: NSSplitView) {
        self.splitView = splitView
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .flexibleSpace]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == .sidebarTrackingSeparator, let splitView else { return nil }
        return NSTrackingSeparatorToolbarItem(
            identifier: itemIdentifier,
            splitView: splitView,
            dividerIndex: 0
        )
    }
}

/// Ensures the hosting settings window keeps System Settings-style chrome after SwiftUI layout.
struct SettingsWindowConfiguratorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            SettingsWindowConfigurator.applyPostLayoutChrome(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            SettingsWindowConfigurator.applyPostLayoutChrome(to: window)
        }
    }
}
