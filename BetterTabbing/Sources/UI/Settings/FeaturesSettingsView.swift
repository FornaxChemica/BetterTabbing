import SwiftUI

struct FeaturesSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section {
                Text("Turn features on or off and customize their shortcuts.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section {
                moduleSection(
                    title: "Window Slots",
                    footer: "Jump to numbered windows globally. Digits 1-9 stay fixed; only the modifier can be changed.",
                    isEnabled: moduleBinding(\.windowSlotsEnabled)
                ) {
                    shortcutSettingRow(title: "Jump to slot", action: .windowSlotModifier, isEnabled: appState.preferences.modules.windowSlotsEnabled)
                }

                moduleSection(
                    title: "Window History",
                    footer: "Undo and redo recent window visits when the switcher is closed.",
                    isEnabled: moduleBinding(\.windowHistoryEnabled)
                ) {
                    shortcutSettingRow(title: "Back", action: .windowHistoryBack, isEnabled: appState.preferences.modules.windowHistoryEnabled)
                    shortcutSettingRow(title: "Forward", action: .windowHistoryForward, isEnabled: appState.preferences.modules.windowHistoryEnabled)
                }

                moduleSection(
                    title: "Workspace Switcher",
                    footer: "Opens the WindowLens overlay. A quick tap on the same shortcut switches windows within the frontmost app.",
                    isEnabled: moduleBinding(\.workspaceSwitcherEnabled)
                ) {
                    shortcutSettingRow(title: "Open workspace", action: .workspaceOpen, isEnabled: appState.preferences.modules.workspaceSwitcherEnabled)
                }

                moduleSection(
                    title: "Resource Monitor",
                    footer: "Toggle the live CPU and memory panel while the switcher is open. Hold the same key for AI insight.",
                    isEnabled: moduleBinding(\.resourceMonitorEnabled)
                ) {
                    shortcutSettingRow(title: "Toggle monitor", action: .resourceMonitorToggle, isEnabled: appState.preferences.modules.resourceMonitorEnabled)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Features")
    }

    private func moduleBinding(_ keyPath: WritableKeyPath<UserPreferences.ModuleSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { appState.preferences.modules[keyPath: keyPath] },
            set: { newValue in
                var updated = appState.preferences
                updated.modules[keyPath: keyPath] = newValue
                appState.preferences = updated
            }
        )
    }

    @ViewBuilder
    private func moduleSection<Content: View>(
        title: String,
        footer: String,
        isEnabled: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Section {
            Toggle(title, isOn: isEnabled)
            content()
                .disabled(!isEnabled.wrappedValue)
                .opacity(isEnabled.wrappedValue ? 1 : 0.55)
        } footer: {
            Text(footer)
        }
    }

    private func shortcutSettingRow(title: String, action: ShortcutAction, isEnabled: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            ShortcutRecorderButton(
                action: action,
                preferences: Binding(
                    get: { appState.preferences.shortcuts },
                    set: { newValue in
                        var updated = appState.preferences
                        updated.shortcuts = newValue
                        appState.preferences = updated
                    }
                ),
                isEnabled: isEnabled
            )
        }
    }
}
