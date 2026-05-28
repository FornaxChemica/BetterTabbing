import AppKit
import SwiftUI

struct WindowListView: View {
    @EnvironmentObject private var appState: AppState

    let app: ApplicationModel
    let selectedWindowIndex: Int
    var presentationMode: SwitcherPresentationMode = .workspace
    var onWindowHovered: ((Int) -> Void)? = nil
    var onWindowClicked: ((Int) -> Void)? = nil

    private var surfaceItems: [WindowSurfaceItem] {
        app.windows.enumerated().map { index, window in
            WindowSurfaceItem(
                id: window.compositorIdentity(ownerPID: app.pid),
                index: index,
                window: window
            )
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .center, spacing: app.hasMultipleWindows ? 18 : 0) {
                        ForEach(surfaceItems) { item in
                            WindowPreviewSurfaceView(
                                window: item.window,
                                appName: app.name,
                                appIcon: app.icon,
                                isSelected: item.index == selectedWindowIndex,
                                distanceFromSelection: abs(item.index - selectedWindowIndex),
                                presentationMode: presentationMode,
                                onHover: { isHovering in
                                    if isHovering {
                                        onWindowHovered?(item.index)
                                    }
                                }
                            )
                            .onTapGesture {
                                onWindowClicked?(item.index)
                            }
                            .zIndex(item.index == selectedWindowIndex ? 10 : Double(5 - abs(item.index - selectedWindowIndex)))
                        }
                    }
                    .frame(minWidth: geometry.size.width, alignment: app.hasMultipleWindows ? .leading : .center)
                    .padding(.horizontal, app.hasMultipleWindows ? 18 : 0)
                    .padding(.vertical, 18)
                }
                .onChange(of: selectedWindowIndex) { oldValue, newValue in
                    guard surfaceItems.indices.contains(newValue) else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(surfaceItems[newValue].id, anchor: .center)
                    }
                }
            }
        }
        .frame(height: presentationMode == .nativePreview ? 306 : 326)
        .onAppear {
            requestMissingPreviews()
        }
        .onChange(of: app.id) { oldValue, newValue in
            requestMissingPreviews()
        }
        .onChange(of: app.windows.map(\.windowID)) { oldValue, newValue in
            requestMissingPreviews()
        }
        .onChange(of: app.windows.map(\.title)) { oldValue, newValue in
            requestMissingPreviews()
        }
        .onChange(of: app.windows.map(\.bounds)) { oldValue, newValue in
            requestMissingPreviews()
        }
        .onChange(of: selectedWindowIndex) { oldValue, newValue in
            requestMissingPreviews()
        }
        .onReceive(NotificationCenter.default.publisher(for: .windowPreviewDidLoad)) { notification in
            guard let update = notification.object as? WindowPreviewUpdate else {
                return
            }

            guard update.ownerPID == nil || update.ownerPID == app.pid else { return }
            guard app.windows.contains(where: { $0.windowID == update.windowID }) else { return }

            appState.setWindowPreview(update)
        }
    }

    private func requestMissingPreviews() {
        WindowPreviewService.shared.requestPreviews(
            for: app.windows,
            ownerPID: app.pid,
            appName: app.name
        )
    }
}

private struct WindowSurfaceItem: Identifiable, Equatable {
    let id: String
    let index: Int
    let window: WindowModel
}

private struct WindowPreviewSurfaceView: View {
    let window: WindowModel
    let appName: String
    let appIcon: NSImage
    let isSelected: Bool
    let distanceFromSelection: Int
    let presentationMode: SwitcherPresentationMode
    var onHover: ((Bool) -> Void)? = nil

    @State private var isHovered = false

    private var geometry: AdaptivePreviewGeometry {
        AdaptivePreviewGeometry(window: window, presentationMode: presentationMode)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ZStack {
                Color.black.opacity(0.10)

                if let previewImage = window.previewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.visualSize.width, height: geometry.visualSize.height)
                        .clipped()
                        .transition(.opacity.animation(.easeOut(duration: 0.16)))
                } else {
                    WindowPreviewPlaceholder(isMinimized: window.isMinimized, geometry: geometry)
                        .frame(width: geometry.visualSize.width, height: geometry.visualSize.height)
                }
            }
            .frame(width: geometry.visualSize.width, height: geometry.visualSize.height)
            .clipShape(RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous))
            .overlay(previewBorder)
            .shadow(
                color: .black.opacity(isSelected ? 0.22 : 0.10),
                radius: isSelected ? 22 : 10,
                x: 0,
                y: isSelected ? 14 : 7
            )
            .shadow(
                color: .white.opacity(isSelected ? 0.06 : 0.0),
                radius: 18,
                x: 0,
                y: 0
            )

            metadataPill
                .padding(.leading, geometry.metadataInset)
                .padding(.bottom, geometry.metadataInset)
        }
        .frame(width: geometry.visualSize.width, height: geometry.visualSize.height, alignment: .bottomLeading)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .offset(y: isSelected ? -6 : (isHovered ? -2 : 8))
        .opacity(cardOpacity)
        .animation(.easeInOut(duration: 0.18), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.16), value: window.previewImage != nil)
        .contentShape(RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous))
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                onHover?(true)
            }
        }
    }

    private var metadataPill: some View {
        HStack(spacing: geometry.isMetadataCompact ? 6 : 8) {
            if geometry.metadataWidth >= 92 {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: geometry.isMetadataCompact ? 16 : 18, height: geometry.isMetadataCompact ? 16 : 18)
                    .cornerRadius(4)
                    .layoutPriority(1)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(window.title)
                    .font(.system(size: geometry.isMetadataCompact ? 10 : 11, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if presentationMode == .workspace && !geometry.isMetadataCompact {
                    Text(appName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            if window.isMinimized && geometry.metadataWidth >= 178 {
                Text("Minimized")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                    )
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, geometry.isMetadataCompact ? 7 : 9)
        .padding(.vertical, 7)
        .frame(width: geometry.metadataWidth, alignment: .leading)
        .background(
            GlassBackground(
                cornerRadius: 12,
                tintOpacity: 0.045,
                strokeOpacity: 0.06,
                shadowOpacity: 0.05,
                shadowRadius: 8,
                shadowYOffset: 4
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipped()
    }

    private var cardOpacity: Double {
        if isSelected { return 1.0 }
        if isHovered { return 0.94 }
        return distanceFromSelection == 1 ? 0.82 : 0.68
    }

    private var previewBorder: some View {
        RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous)
            .strokeBorder(isSelected ? Color.white.opacity(0.24) : Color.white.opacity(0.075), lineWidth: isSelected ? 1.0 : 0.6)
    }
}

private struct AdaptivePreviewGeometry: Equatable {
    let visualSize: CGSize
    let cornerRadius: CGFloat

    var metadataInset: CGFloat {
        visualSize.width < 160 ? 8 : 10
    }

    var metadataWidth: CGFloat {
        max(64, visualSize.width - metadataInset * 2)
    }

    var isMetadataCompact: Bool {
        metadataWidth < 164
    }

    init(window: WindowModel, presentationMode: SwitcherPresentationMode) {
        let constraints = Constraints(presentationMode: presentationMode)
        let sourceSize = Self.sourceSize(for: window)
        let aspect = Self.clampedAspectRatio(for: sourceSize)
        let mass = Self.visualMassBand(for: sourceSize, hasReliableBounds: Self.hasReliableBounds(window.bounds))

        var height = constraints.referenceHeight * mass
        var width = height * aspect

        if width > constraints.maximumWidth {
            let scale = constraints.maximumWidth / width
            width *= scale
            height *= scale
        }

        if height > constraints.maximumHeight {
            let scale = constraints.maximumHeight / height
            width *= scale
            height *= scale
        }

        if width < constraints.minimumWidth {
            let scale = min(constraints.maximumVisibilityBoost, constraints.minimumWidth / max(width, 1))
            width *= scale
            height *= scale
        }

        if height < constraints.minimumHeight {
            let scale = min(constraints.maximumVisibilityBoost, constraints.minimumHeight / max(height, 1))
            width *= scale
            height *= scale
        }

        width = min(max(width, constraints.absoluteMinimumWidth), constraints.maximumWidth)
        height = min(max(height, constraints.absoluteMinimumHeight), constraints.maximumHeight)

        let roundedSize = CGSize(width: width.rounded(), height: height.rounded())
        self.visualSize = roundedSize
        self.cornerRadius = min(17, max(11, min(roundedSize.width, roundedSize.height) * 0.055))
    }

    private static func sourceSize(for window: WindowModel) -> CGSize {
        if hasReliableBounds(window.bounds) {
            return window.bounds.size
        }

        if let image = window.previewImage, image.size.width > 1, image.size.height > 1 {
            return image.size
        }

        return CGSize(width: 1100, height: 720)
    }

    private static func hasReliableBounds(_ bounds: CGRect) -> Bool {
        bounds.width > 16 && bounds.height > 16
    }

    private static func clampedAspectRatio(for size: CGSize) -> CGFloat {
        let rawAspect = size.width / max(size.height, 1)
        return min(max(rawAspect, 0.58), 2.25)
    }

    private static func visualMassBand(for size: CGSize, hasReliableBounds: Bool) -> CGFloat {
        guard hasReliableBounds else { return 0.98 }

        let area = size.width * size.height
        if area < 240_000 { return 0.76 }
        if area < 700_000 { return 0.92 }
        if area < 1_400_000 { return 1.04 }
        return 1.14
    }

    private struct Constraints {
        let referenceHeight: CGFloat
        let minimumWidth: CGFloat
        let minimumHeight: CGFloat
        let absoluteMinimumWidth: CGFloat
        let absoluteMinimumHeight: CGFloat
        let maximumWidth: CGFloat
        let maximumHeight: CGFloat
        let maximumVisibilityBoost: CGFloat

        init(presentationMode: SwitcherPresentationMode) {
            switch presentationMode {
            case .nativePreview:
                referenceHeight = 218
                minimumWidth = 126
                minimumHeight = 122
                absoluteMinimumWidth = 118
                absoluteMinimumHeight = 112
                maximumWidth = 410
                maximumHeight = 246
                maximumVisibilityBoost = 1.16
            case .workspace:
                referenceHeight = 228
                minimumWidth = 132
                minimumHeight = 128
                absoluteMinimumWidth = 122
                absoluteMinimumHeight = 118
                maximumWidth = 440
                maximumHeight = 260
                maximumVisibilityBoost = 1.18
            }
        }
    }
}

private struct WindowPreviewPlaceholder: View {
    let isMinimized: Bool
    let geometry: AdaptivePreviewGeometry

    var body: some View {
        ZStack {
            Color.white.opacity(0.028)

            VStack(spacing: geometry.visualSize.width < 160 ? 5 : 8) {
                Image(systemName: isMinimized ? "minus.rectangle" : "macwindow")
                    .font(.system(size: geometry.visualSize.width < 160 ? 20 : 26, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(isMinimized ? "Minimized" : "Preview")
                    .font(.system(size: geometry.visualSize.width < 160 ? 9 : 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
