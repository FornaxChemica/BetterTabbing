import SwiftUI

struct AppTileView: View {
    let app: ApplicationModel
    let isSelected: Bool
    let namespace: Namespace.ID  // Kept for API compatibility but not used
    var isQuitHoldActive: Bool = false
    var quitHoldProgress: CGFloat = 0.0
    var onHover: ((Bool) -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // Selection/hover background
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(backgroundColor)

                if isSelected && !isQuitHoldActive {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                }

                // App icon
                Image(nsImage: app.icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 46, height: 46)
                    .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
                    .opacity(isQuitHoldActive ? 0.6 : 1.0)

                // Quit hold progress ring overlay
                if isQuitHoldActive {
                    CircularProgressRing(
                        progress: quitHoldProgress,
                        color: .red,
                        lineWidth: 3,
                        size: 56
                    )
                }
            }
            .frame(width: 58, height: 58)

            // App name with window count inline
            HStack(spacing: 4) {
                Text(app.name)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if app.hasMultipleWindows {
                    Text("·\(app.windowCount)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: 76)
        }
        .padding(5)
        .contentShape(Rectangle())
        .scaleEffect(isSelected ? 1.015 : (isHovered ? 1.008 : 1.0))
        .opacity(isSelected ? 1 : 0.88)
        .animation(.spring(response: 0.22, dampingFraction: 0.86), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                onHover?(true)
            }
        }
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.white.opacity(0.075)
        } else if isHovered {
            return Color.white.opacity(0.045)
        } else {
            return Color.clear
        }
    }
}
