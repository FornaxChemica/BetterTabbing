import AppKit
import SwiftUI

struct WindowSlotAssignmentOption: Identifiable {
    let windowID: CGWindowID
    let pid: pid_t
    let bundleIdentifier: String
    let appName: String
    let windowTitle: String
    let icon: NSImage?
    let currentSlot: Int?

    var id: CGWindowID { windowID }

    var displayTitle: String {
        windowTitle.isEmpty ? "Untitled window" : windowTitle
    }
}

struct WindowSlotAssignmentSheet: View {
    let slot: Int

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var registry = WindowNumberRegistry.shared
    @State private var options: [WindowSlotAssignmentOption] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading windows…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if options.isEmpty {
                    ContentUnavailableView(
                        "No Windows Available",
                        systemImage: "macwindow.on.rectangle",
                        description: Text("Open at least one app window, then try again.")
                    )
                } else {
                    List(options) { option in
                        Button {
                            assign(option)
                        } label: {
                            HStack(spacing: 10) {
                                if let icon = option.icon {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .frame(width: 20, height: 20)
                                } else {
                                    Image(systemName: "app")
                                        .frame(width: 20, height: 20)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.appName)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                    Text(option.displayTitle)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                if let currentSlot = option.currentSlot {
                                    Text("Slot \(currentSlot)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Assign Slot \(slot)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 460, minHeight: 380)
        .onAppear {
            loadOptions()
        }
    }

    private func loadOptions() {
        isLoading = true
        let apps = WindowCache.shared.getApplicationsSync(forceRefresh: true)
        var loaded: [WindowSlotAssignmentOption] = []

        for app in apps {
            for window in app.windows where !window.isMinimized && !window.isWindowlessPlaceholder {
                let runningApp = NSRunningApplication(processIdentifier: app.pid)
                loaded.append(
                    WindowSlotAssignmentOption(
                        windowID: window.windowID,
                        pid: app.pid,
                        bundleIdentifier: app.bundleIdentifier,
                        appName: app.name,
                        windowTitle: window.title,
                        icon: runningApp?.icon,
                        currentSlot: registry.assignedSlot(for: window.windowID)
                    )
                )
            }
        }

        loaded.sort { lhs, rhs in
            let left = "\(lhs.appName) \(lhs.windowTitle)"
            let right = "\(rhs.appName) \(rhs.windowTitle)"
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }

        options = loaded
        isLoading = false
    }

    private func assign(_ option: WindowSlotAssignmentOption) {
        registry.reassign(
            slot: slot,
            to: option.windowID,
            pid: option.pid,
            appName: option.appName,
            windowTitle: option.windowTitle,
            bundleIdentifier: option.bundleIdentifier
        )
        dismiss()
    }
}
