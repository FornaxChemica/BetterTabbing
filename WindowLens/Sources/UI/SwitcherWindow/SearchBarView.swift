import SwiftUI

struct SearchBarView: View {
    @Binding var searchQuery: String
    @FocusState.Binding var isFocused: Bool
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search apps and windows...", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .onSubmit {
                    onSubmit()
                }

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            GlassBackground(
                cornerRadius: 14,
                tintOpacity: 0.04,
                strokeOpacity: 0.08,
                shadowOpacity: 0.08,
                shadowRadius: 12,
                shadowYOffset: 6
            )
        )
    }
}
