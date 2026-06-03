import AppKit
import SwiftUI

@main
struct WindowLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            MenuBarIconLabel()
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuBarIconLabel: View {
    var body: some View {
        if let icon = Self.templateMenuBarImage() {
            Image(nsImage: icon)
                .renderingMode(.template)
        } else {
            Image(systemName: "rectangle.on.rectangle")
        }
    }

    private static func templateMenuBarImage() -> NSImage? {
        guard let image = NSImage(named: "MenuBarIcon")?.copy() as? NSImage else {
            return nil
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }
}

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var visitHistory = WindowVisitHistory.shared

    private var workspaceShortcut: String {
        appState.preferences.shortcuts.workspaceOpen.displayString
    }

    private var historyBackShortcut: String {
        appState.preferences.shortcuts.windowHistoryBack.displayString
    }

    private var historyForwardShortcut: String {
        appState.preferences.shortcuts.windowHistoryForward.displayString
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("WindowLens")
                .font(.headline)

            Divider()

            HStack {
                Text("Workspace:")
                Spacer()
                Text(workspaceShortcut)
                    .foregroundStyle(.secondary)
            }

            Text("History: \(historyBackShortcut) back · \(historyForwardShortcut) forward")
                .font(.caption)
                .foregroundStyle(.secondary)

            let recentVisits = visitHistory.recentVisitsForMenu()
            if !recentVisits.isEmpty {
                Divider()

                Text("Recent Windows")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(recentVisits) { visit in
                    Button(visit.menuLabel) {
                        visitHistory.jumpToVisit(visit)
                    }
                }
            }

            Divider()

            Button("Settings…") {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Reinstall Event Tap") {
                NotificationCenter.default.post(name: .reinstallEventTap, object: nil)
            }

            Button("Open Permissions") {
                NotificationCenter.default.post(name: .openPermissions, object: nil)
            }

            Divider()

            Button("Quit WindowLens") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(8)
    }
}
