import SwiftUI

struct HeatmapSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section {
                Text("Visualize when and how much you use each open app by time of day and day of week.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Default range", selection: defaultRangeBinding) {
                    ForEach(UserPreferences.HeatmapDefaultTimeRange.allCases) { range in
                        Text(range.displayName).tag(range)
                    }
                }

                Button("Open Usage Heatmap") {
                    openHeatmap()
                }
                .disabled(!appState.preferences.modules.usageHeatmapEnabled)
            } footer: {
                Text("The heatmap only lists apps that are currently running. Window actions require Accessibility permission.")
            }

            Section("Data") {
                Text("Usage is recorded when you focus windows through WindowLens or normal app switching.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Usage Heatmap")
    }

    private var defaultRangeBinding: Binding<UserPreferences.HeatmapDefaultTimeRange> {
        Binding(
            get: { appState.preferences.heatmap.defaultTimeRange },
            set: { newValue in
                var updated = appState.preferences
                updated.heatmap.defaultTimeRange = newValue
                appState.preferences = updated
            }
        )
    }

    private func openHeatmap() {
        NotificationCenter.default.post(name: .openHeatmap, object: nil)
    }
}
