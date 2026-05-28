import AppKit
import SwiftUI

struct WindowListView: View {
    @EnvironmentObject private var appState: AppState

    let app: ApplicationModel
    let selectedWindowIndex: Int
    var onWindowHovered: ((Int) -> Void)? = nil
    var onWindowClicked: ((Int) -> Void)? = nil

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: app.hasMultipleWindows ? -14 : 0) {
                        ForEach(Array(app.windows.enumerated()), id: \.element.id) { index, window in
                            WindowPreviewCardView(
                                window: window,
                                appName: app.name,
                                appIcon: app.icon,
                                isSelected: index == selectedWindowIndex,
                                distanceFromSelection: abs(index - selectedWindowIndex),
                                onHover: { isHovering in
                                    if isHovering {
                                        onWindowHovered?(index)
                                    }
                                }
                            )
                            .id(index)
                            .onTapGesture {
                                onWindowClicked?(index)
                            }
                            .zIndex(index == selectedWindowIndex ? 10 : Double(5 - abs(index - selectedWindowIndex)))
                        }
                    }
                    .frame(minWidth: geometry.size.width, alignment: app.hasMultipleWindows ? .leading : .center)
                    .padding(.horizontal, app.hasMultipleWindows ? 22 : 0)
                    .padding(.vertical, 18)
                }
                .onChange(of: selectedWindowIndex) { oldValue, newValue in
                    withAnimation(.smooth(duration: 0.16)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        .frame(height: 230)
        .onAppear {
            requestMissingPreviews()
        }
        .onChange(of: app.id) { oldValue, newValue in
            requestMissingPreviews()
        }
        .onChange(of: app.windows.map(\.windowID)) { oldValue, newValue in
            requestMissingPreviews()
        }
        .onReceive(NotificationCenter.default.publisher(for: .windowPreviewDidLoad)) { notification in
            guard let update = notification.object as? WindowPreviewUpdate,
                  app.windows.contains(where: { $0.windowID == update.windowID }) else {
                return
            }

            appState.setWindowPreview(update.image, for: update.windowID)
        }
    }

    private func requestMissingPreviews() {
        WindowPreviewService.shared.requestPreviews(for: app.windows)
    }
}

private struct WindowPreviewCardView: View {
    let window: WindowModel
    let appName: String
    let appIcon: NSImage
    let isSelected: Bool
    let distanceFromSelection: Int
    var onHover: ((Bool) -> Void)? = nil

    @State private var isHovered = false

    private let previewSize = CGSize(width: 268, height: 154)

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack {
                if let previewImage = window.previewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: previewSize.width, height: previewSize.height)
                        .clipped()
                        .overlay(previewScrim)
                        .overlay(alignment: .top) {
                            SubtleWindowChrome()
                        }
                        .transition(.opacity.animation(.easeOut(duration: 0.16)))
                } else {
                    WindowPreviewPlaceholder(isMinimized: window.isMinimized)
                        .frame(width: previewSize.width, height: previewSize.height)
                }
            }
            .frame(width: previewSize.width, height: previewSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(previewBorder)
            .shadow(
                color: .black.opacity(isSelected ? 0.30 : 0.13),
                radius: isSelected ? 22 : 10,
                x: 0,
                y: isSelected ? 14 : 5
            )

            HStack(spacing: 8) {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
                    .cornerRadius(4)

                VStack(alignment: .leading, spacing: 1) {
                    Text(window.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(appName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if window.isMinimized {
                    Text("min")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.08))
                        )
                }
            }
            .frame(width: previewSize.width, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .scaleEffect(cardScale)
        .offset(y: isSelected ? -5 : (isHovered ? -2 : 0))
        .opacity(cardOpacity)
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.16), value: window.previewImage != nil)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                onHover?(true)
            }
        }
    }

    private var cardScale: CGFloat {
        if isSelected { return 1.04 }
        if distanceFromSelection == 1 { return isHovered ? 0.98 : 0.95 }
        return isHovered ? 0.94 : 0.91
    }

    private var cardOpacity: Double {
        if isSelected { return 1.0 }
        if isHovered { return 0.92 }
        return distanceFromSelection == 1 ? 0.72 : 0.54
    }

    private var previewBorder: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(isSelected ? Color.white.opacity(0.22) : Color.white.opacity(0.10), lineWidth: 0.75)
    }

    private var previewScrim: some View {
        LinearGradient(
            colors: [
                Color.black.opacity(0.0),
                Color.black.opacity(0.08)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct SubtleWindowChrome: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.red.opacity(0.28))
                .frame(width: 7, height: 7)
            Circle()
                .fill(Color.yellow.opacity(0.25))
                .frame(width: 7, height: 7)
            Circle()
                .fill(Color.green.opacity(0.25))
                .frame(width: 7, height: 7)

            Spacer()
        }
        .frame(height: 18)
        .padding(.horizontal, 9)
        .background(
            LinearGradient(
                colors: [
                    Color.black.opacity(0.16),
                    Color.black.opacity(0.02)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .allowsHitTesting(false)
    }
}

private struct WindowPreviewPlaceholder: View {
    let isMinimized: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.white.opacity(0.10),
                    Color.white.opacity(0.035)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 8) {
                Image(systemName: isMinimized ? "minus.rectangle" : "macwindow")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(isMinimized ? "Minimized" : "Preview")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
