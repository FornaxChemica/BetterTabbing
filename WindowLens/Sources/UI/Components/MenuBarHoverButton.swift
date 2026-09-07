import SwiftUI

enum MenuBarHoverStyle {
    /// Soft selection fill used by modern macOS menu / Control Center rows (not accent blue).
    static let fillOpacity: Double = 0.10
    static let cornerRadius: CGFloat = 6

    static var fill: Color { Color.primary.opacity(fillOpacity) }
}

/// Menu-row button with native light-grey hover highlight (macOS 26-style).
struct MenuBarHoverButton<Label: View>: View {
    var horizontalPadding: CGFloat = 8
    var verticalPadding: CGFloat = 6
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: MenuBarHoverStyle.cornerRadius, style: .continuous)
                        .fill(isHovered ? MenuBarHoverStyle.fill : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovered != hovering else { return }
            withAnimation(.easeOut(duration: 0.08)) {
                isHovered = hovering
            }
        }
    }
}

/// Applies the same light-grey hover fill to any row (e.g. toggle rows that are already buttons).
struct MenuBarHoverBackground: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: MenuBarHoverStyle.cornerRadius, style: .continuous)
                    .fill(isHovered ? MenuBarHoverStyle.fill : Color.clear)
            )
            .onHover { hovering in
                guard isHovered != hovering else { return }
                withAnimation(.easeOut(duration: 0.08)) {
                    isHovered = hovering
                }
            }
    }
}

extension View {
    func menuBarHoverBackground() -> some View {
        modifier(MenuBarHoverBackground())
    }
}
