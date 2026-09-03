import AppKit
import SwiftUI

struct WindowListView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var slotRegistry = WindowNumberRegistry.shared

    let app: ApplicationModel
    let selectedWindowIndex: Int
    var presentationMode: SwitcherPresentationMode = .workspace
    var onWindowHovered: ((Int) -> Void)? = nil
    var onWindowClicked: ((Int) -> Void)? = nil

    private var surfaceItems: [WindowSurfaceItem] {
        app.windows.enumerated().map { index, window in
            WindowSurfaceItem(
                id: carouselItemID(for: window),
                index: index,
                window: window
            )
        }
    }

    private func carouselItemID(for window: WindowModel) -> String {
        if presentationMode == .workspace && appState.workspaceMode == .currentAppWindows {
            return window.carouselItemID
        }
        return window.previewIdentity.surfaceID
    }

    /// Real open-window count for global-search carousel layout (stable when bounds/titles change).
    private var previewLayoutWindowCount: Int {
        app.openWindowCount
    }

    private var carouselSpacing: CGFloat {
        if isSearchResultsPreviewPane, previewLayoutWindowCount >= 2, previewLayoutWindowCount <= 3 {
            return 14
        }
        return app.openWindowCount >= 2 ? 18 : 0
    }

    var body: some View {
        GeometryReader { geometry in
            if usesCenteredNonScrollingCarousel {
                centeredCarousel(in: geometry)
            } else {
                scrollingCarousel(in: geometry)
            }
        }
        .frame(height: presentationMode == .nativePreview ? 348 : 372)
        .onAppear {
            // Defer ScreenCaptureKit until after first paint; only selected ± neighbors.
            requestMissingPreviews(nearSelectionOnly: true)
        }
        .onChange(of: app.id) { oldValue, newValue in
            requestMissingPreviews()
        }
        .onChange(of: app.windows.map(\.carouselItemID)) { oldValue, newValue in
            guard oldValue != newValue else { return }
            requestMissingPreviews()
        }
        .onChange(of: app.windows.map(\.title)) { oldValue, newValue in
            guard presentationMode != .nativePreview else { return }
            requestMissingPreviews()
        }
        .onChange(of: app.windows.map(\.bounds)) { oldValue, newValue in
            guard presentationMode != .nativePreview else { return }
            requestMissingPreviews()
        }
        .onChange(of: selectedWindowIndex) { oldValue, newValue in
            requestMissingPreviews(nearSelectionOnly: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .windowPreviewDidLoad)) { notification in
            guard let update = notification.object as? WindowPreviewUpdate else {
                return
            }

            guard update.ownerPID == nil || update.ownerPID == app.pid else { return }
            guard app.windows.contains(where: { $0.previewIdentity.matches(update.previewIdentity) }) else { return }

            appState.setWindowPreview(update)
        }
    }

    private var isNativePreviewCarousel: Bool {
        presentationMode == .nativePreview
    }

    private var isCurrentAppWorkspaceCarousel: Bool {
        presentationMode == .workspace && appState.workspaceMode == .currentAppWindows
    }

    private var isGlobalWindowSearchCarousel: Bool {
        presentationMode == .workspace && appState.workspaceMode == .globalWindowSearch
    }

    private var isSearchResultsPreviewPane: Bool {
        presentationMode == .workspace && appState.workspaceMode == .globalWindowSearch
    }

    private var usesAdaptiveWindowCarousel: Bool {
        isNativePreviewCarousel || isCurrentAppWorkspaceCarousel || isGlobalWindowSearchCarousel
    }

    /// Room for selected-card scale/offset so ScrollView does not clip metadata or corners.
    private var horizontalOverflowPadding: CGFloat {
        if isSearchResultsPreviewPane {
            switch previewLayoutWindowCount {
            case 1: return 28
            case 2: return 40
            case 3: return 36
            default: return 44
            }
        }
        if usesCenteredNonScrollingCarousel {
            return 0
        }
        return presentationMode == .workspace ? 40 : 0
    }

    /// Up to 3 windows: centered HStack without ScrollView (matches Cmd+Tab preview — no edge clipping).
    private var usesCenteredNonScrollingCarousel: Bool {
        if isSearchResultsPreviewPane {
            return false
        }
        return shouldUseCenteredHStackLayout
    }

    @ViewBuilder
    private func centeredCarousel(in geometry: GeometryProxy) -> some View {
        liquidGlassGroup {
            HStack(spacing: carouselSpacing) {
                Spacer(minLength: 0)
                carouselItems(in: geometry)
                Spacer(minLength: 0)
            }
            .frame(width: geometry.size.width)
            .padding(.horizontal, app.openWindowCount >= 2 ? 22 : 0)
            .padding(.vertical, 18)
        }
    }

    @ViewBuilder
    private func scrollingCarousel(in geometry: GeometryProxy) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                liquidGlassGroup {
                    HStack(alignment: .center, spacing: carouselSpacing) {
                        carouselItems(in: geometry)
                    }
                    .frame(
                        minWidth: geometry.size.width,
                        alignment: shouldUseCenteredHStackLayout ? .center : (app.openWindowCount >= 2 ? .leading : .center)
                    )
                    .padding(.horizontal, app.openWindowCount >= 2 ? 22 : 0)
                    .padding(.vertical, 18)
                }
            }
            .contentMargins(.horizontal, horizontalOverflowPadding, for: .scrollContent)
            .scrollClipDisabled()
            .mask(scrollMask)
            .onAppear {
                centerCarouselSelection(with: proxy, animated: false)
            }
            .onChange(of: geometry.size.width) { _, _ in
                centerCarouselSelection(with: proxy, animated: false)
            }
            .onChange(of: selectedWindowIndex) { _, _ in
                centerCarouselSelection(
                    with: proxy,
                    animated: shouldAnimateCarouselScroll
                )
            }
        }
    }

    @ViewBuilder
    private func carouselItems(in geometry: GeometryProxy) -> some View {
        ForEach(surfaceItems) { item in
            let isSelected = item.index == selectedWindowIndex
            let distance = abs(item.index - selectedWindowIndex)
            WindowPreviewSurfaceView(
                window: item.window,
                appName: app.name,
                appIcon: app.icon,
                isSelected: isSelected,
                distanceFromSelection: distance,
                presentationMode: presentationMode,
                maximumPreviewWidth: maximumPreviewWidth(
                    containerWidth: geometry.size.width,
                    isSelected: isSelected,
                    distanceFromSelection: distance
                ),
                globalSearchWindowCount: isSearchResultsPreviewPane ? previewLayoutWindowCount : nil,
                onHover: { isHovering in
                    if isHovering {
                        onWindowHovered?(item.index)
                    }
                }
            )
            .contextMenu {
                ForEach(1...9, id: \.self) { slot in
                    Button {
                        slotRegistry.reassign(
                            slot: slot,
                            to: item.window.windowID,
                            pid: app.pid,
                            appName: app.name,
                            windowTitle: item.window.title,
                            bundleIdentifier: app.bundleIdentifier
                        )
                    } label: {
                        slotAssignmentMenuLabel(
                            slot: slot,
                            currentWindowID: item.window.windowID
                        )
                    }
                }
            }
            .onTapGesture {
                onWindowClicked?(item.index)
            }
            .zIndex(item.index == selectedWindowIndex ? 10 : Double(5 - abs(item.index - selectedWindowIndex)))
            .id(item.id)
        }
    }

    private func centerCarouselSelection(with proxy: ScrollViewProxy, animated: Bool) {
        guard shouldScrollToSelection,
              surfaceItems.indices.contains(selectedWindowIndex) else {
            return
        }

        let targetID = surfaceItems[selectedWindowIndex].id

        guard animated else {
            DispatchQueue.main.async {
                proxy.scrollTo(targetID, anchor: .center)
            }
            return
        }

        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            proxy.scrollTo(targetID, anchor: .center)
        }
    }

    /// Centers the HStack content when all cards fit without horizontal scrolling.
    private var shouldUseCenteredHStackLayout: Bool {
        if isSearchResultsPreviewPane {
            return previewLayoutWindowCount <= 3
        }
        guard usesAdaptiveWindowCarousel, surfaceItems.count <= 3 else { return false }
        return true
    }

    private var shouldScrollToSelection: Bool {
        !usesCenteredNonScrollingCarousel
    }

    private var shouldAnimateCarouselScroll: Bool {
        presentationMode != .nativePreview
            && (isSearchResultsPreviewPane || isCurrentAppWorkspaceCarousel)
    }

    private var usesPeekMask: Bool {
        guard usesAdaptiveWindowCarousel else { return false }
        if isSearchResultsPreviewPane {
            return previewLayoutWindowCount >= 4
        }
        return previewLayoutWindowCount >= 4
    }

    private var scrollMask: some View {
        Group {
            if usesPeekMask {
                HStack(spacing: 0) {
                    LinearGradient(
                        colors: [.clear, .black],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 42)

                    Rectangle()
                        .fill(.black)

                    LinearGradient(
                        colors: [.black, .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 42)
                }
            } else {
                Rectangle()
                    .fill(.black)
            }
        }
    }

    @ViewBuilder
    private func liquidGlassGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(macOS 26.0, *), presentationMode == .nativePreview {
            GlassEffectContainer(spacing: app.openWindowCount >= 2 ? 18 : 0) {
                content()
            }
        } else {
            content()
        }
    }

    @ViewBuilder
    private func slotAssignmentMenuLabel(slot: Int, currentWindowID: CGWindowID) -> some View {
        if let occupant = slotRegistry.assignment(for: slot),
           occupant.isAlive,
           occupant.windowID != currentWindowID {
            let title = occupant.windowTitle.isEmpty ? occupant.appName : "\(occupant.appName) · \(occupant.windowTitle)"
            Text("Assign to slot \(slot) (\(title))")
                .foregroundStyle(.secondary)
        } else {
            Text("Assign to slot \(slot)")
        }
    }

    private func maximumPreviewWidth(
        containerWidth: CGFloat,
        isSelected: Bool,
        distanceFromSelection: Int
    ) -> CGFloat? {
        guard usesAdaptiveWindowCarousel else { return nil }

        let count = max(surfaceItems.count, 1)

        if isSearchResultsPreviewPane {
            return globalSearchMaximumPreviewWidth(
                containerWidth: containerWidth,
                windowCount: previewLayoutWindowCount,
                isSelected: isSelected,
                distanceFromSelection: distanceFromSelection
            )
        }

        if count >= 2 && count <= 3 {
            let spacing = CGFloat(count - 1) * 18
            let listPadding: CGFloat = app.openWindowCount >= 2 ? 44 : 0
            let surfacePadding = CGFloat(count) * 28
            let available = containerWidth - spacing - listPadding - surfacePadding
            return min(410, max(150, floor(available / CGFloat(count))))
        }

        if count >= 4 {
            return 410
        }

        return nil
    }

    /// Option+Tab global search preview pane — hero sizing for 3, balanced pair for 2, full width for 1.
    private func globalSearchMaximumPreviewWidth(
        containerWidth: CGFloat,
        windowCount: Int,
        isSelected: Bool,
        distanceFromSelection: Int
    ) -> CGFloat {
        let horizontalInset = (app.openWindowCount >= 2 ? 22 : 0) + horizontalOverflowPadding
        let available = max(containerWidth - horizontalInset * 2, 200)
        let cardChrome: CGFloat = 28

        switch windowCount {
        case 1:
            return min(460, max(300, available - cardChrome * 2))
        case 2:
            let slot = (available - carouselSpacing - cardChrome * 2) / 2
            return min(360, max(260, floor(slot)))
        case 3:
            if isSelected {
                return min(400, max(300, floor(available * 0.58)))
            }
            return min(220, max(168, floor(available * 0.24)))
        default:
            return 410
        }
    }

    private func requestMissingPreviews(nearSelectionOnly: Bool = false) {
        let candidateIndices: [Int]
        if nearSelectionOnly {
            let neighbors = [selectedWindowIndex - 1, selectedWindowIndex, selectedWindowIndex + 1]
            candidateIndices = neighbors.filter { app.windows.indices.contains($0) }
        } else {
            candidateIndices = Array(app.windows.indices)
        }

        let windowsNeedingPreview = candidateIndices.compactMap { index -> WindowModel? in
            let window = app.windows[index]
            guard !window.isWindowlessPlaceholder,
                  !WindowEnumerator.shouldSuppressFinderPreview(for: window),
                  window.previewImage == nil,
                  window.canCapturePreview else {
                return nil
            }
            return window
        }
        guard !windowsNeedingPreview.isEmpty else { return }

        WindowPreviewService.shared.requestPreviews(
            for: windowsNeedingPreview,
            ownerPID: app.pid,
            appName: app.name,
            selectionGeneration: appState.previewRequestGeneration(for: presentationMode)
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
    let maximumPreviewWidth: CGFloat?
    /// When set, tunes card scale/opacity for the Option+Tab global search carousel only.
    let globalSearchWindowCount: Int?
    var onHover: ((Bool) -> Void)? = nil

    @State private var isHovered = false
    @State private var retainedPreview: NSImage?

    private var geometry: AdaptivePreviewGeometry {
        AdaptivePreviewGeometry(
            window: window,
            presentationMode: presentationMode,
            maximumPreviewWidth: maximumPreviewWidth
        )
    }

    private var shouldUseWindowlessPreviewSurface: Bool {
        window.isWindowlessPlaceholder
            || WindowEnumerator.shouldSuppressFinderPreview(for: window)
    }

    private var previewContentAlignment: Alignment {
        shouldUseWindowlessPreviewSurface ? .center : .bottomLeading
    }

    var body: some View {
        ZStack(alignment: previewContentAlignment) {
            if shouldUseWindowlessPreviewSurface {
                WindowlessPreviewSurface(
                    appName: appName,
                    appIcon: appIcon,
                    geometry: geometry
                )
                .frame(width: geometry.visualSize.width, height: geometry.visualSize.height)
            } else {
                ZStack {
                    if let previewImage = displayedPreviewImage {
                        ZStack(alignment: .topTrailing) {
                            Image(nsImage: previewImage)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .frame(width: geometry.visualSize.width, height: geometry.visualSize.height)
                                .clipped()

                            if window.isMinimized {
                                statusPill("Minimized")
                                    .padding(10)
                            }
                        }
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
                    .zIndex(50)
            }
        }
        .frame(width: geometry.visualSize.width, height: geometry.visualSize.height, alignment: previewContentAlignment)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .offset(y: selectionVerticalOffset)
        .scaleEffect(selectionScale, anchor: .center)
        .opacity(cardOpacity)
        .animation(
            globalSearchWindowCount == nil
                ? .spring(response: 0.24, dampingFraction: 0.84)
                : .spring(response: 0.34, dampingFraction: 0.86),
            value: isSelected
        )
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .contentShape(RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous))
        .onAppear {
            guard !shouldUseWindowlessPreviewSurface else {
                retainedPreview = nil
                return
            }

            if let previewImage = window.previewImage {
                syncRetainedPreview(from: previewImage)
            } else if let cachedPreview = WindowPreviewService.shared.cachedPreview(for: window.previewIdentity) {
                syncRetainedPreview(from: cachedPreview)
            }
        }
        .onChange(of: window.id) { _, _ in
            retainedPreview = nil
        }
        .onChange(of: window.previewImage) { _, newValue in
            syncRetainedPreview(from: newValue)
        }
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                onHover?(true)
            }
        }
    }

    private var displayedPreviewImage: NSImage? {
        guard !shouldUseWindowlessPreviewSurface else { return nil }
        return window.previewImage ?? retainedPreview
    }

    private func syncRetainedPreview(from image: NSImage?) {
        guard let image else { return }
        retainedPreview = image
    }

    private var metadataPill: some View {
        NativeLiquidGlassSurface(
            cornerRadius: 12,
            nativeStyle: .clear,
            tintOpacity: 0.02,
            strokeOpacity: 0.06,
            shadowOpacity: 0.04,
            shadowRadius: 8,
            shadowYOffset: 4
        ) {
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
                    metadataMinimizedBadge
                }
            }
            .padding(.horizontal, geometry.isMetadataCompact ? 7 : 9)
            .padding(.vertical, 7)
            .frame(width: geometry.metadataWidth, alignment: .leading)
        }
    }

    private var metadataMinimizedBadge: some View {
        NativeLiquidGlassSurface(
            cornerRadius: 7,
            nativeStyle: .clear,
            tintOpacity: 0.018,
            strokeOpacity: 0.10,
            shadowOpacity: 0.025,
            shadowRadius: 4,
            shadowYOffset: 2
        ) {
            Text("Minimized")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        }
        .layoutPriority(1)
    }

    private var selectionScale: CGFloat {
        if let count = globalSearchWindowCount {
            if isSelected { return count == 3 ? 1.04 : 1.05 }
            if isHovered { return 1.01 }
            switch count {
            case 2: return 0.98
            case 3: return 0.94
            default: return distanceFromSelection == 1 ? 0.96 : 0.92
            }
        }
        if isSelected { return 1.07 }
        if isHovered { return 1.015 }
        return 1.0
    }

    private var selectionVerticalOffset: CGFloat {
        if globalSearchWindowCount != nil {
            if isSelected { return -4 }
            return isHovered ? -1 : 2
        }
        if isSelected { return -6 }
        return isHovered ? -2 : 8
    }

    private var cardOpacity: Double {
        if isSelected { return 1.0 }
        if isHovered { return 0.96 }
        if let count = globalSearchWindowCount {
            switch count {
            case 2: return 0.92
            case 3: return 0.86
            default: return distanceFromSelection == 1 ? 0.82 : 0.68
            }
        }
        return distanceFromSelection == 1 ? 0.82 : 0.68
    }

    private var previewBorder: some View {
        RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous)
            .strokeBorder(isSelected ? Color.white.opacity(0.24) : Color.white.opacity(0.075), lineWidth: isSelected ? 1.0 : 0.6)
    }

    private func statusPill(_ text: String) -> some View {
        NativeLiquidGlassSurface(
            cornerRadius: 11,
            nativeStyle: .regular,
            tintOpacity: 0.02,
            strokeOpacity: 0.13,
            strokeWidth: 0.7,
            shadowOpacity: 0.05,
            shadowRadius: 5,
            shadowYOffset: 2
        ) {
            Text(text)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
        }
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

    init(
        window: WindowModel,
        presentationMode: SwitcherPresentationMode,
        maximumPreviewWidth: CGFloat? = nil
    ) {
        let constraints = Constraints(
            presentationMode: presentationMode,
            maximumPreviewWidth: maximumPreviewWidth
        )
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

        init(presentationMode: SwitcherPresentationMode, maximumPreviewWidth: CGFloat?) {
            switch presentationMode {
            case .nativePreview:
                referenceHeight = 218
                minimumWidth = 126
                minimumHeight = 122
                absoluteMinimumWidth = 118
                absoluteMinimumHeight = 112
                maximumWidth = maximumPreviewWidth ?? 410
                maximumHeight = 246
                maximumVisibilityBoost = 1.16
            case .workspace:
                referenceHeight = 228
                minimumWidth = 132
                minimumHeight = 128
                absoluteMinimumWidth = 122
                absoluteMinimumHeight = 118
                maximumWidth = maximumPreviewWidth ?? 440
                maximumHeight = 260
                maximumVisibilityBoost = 1.18
            }
        }
    }
}

private enum PreviewGlassSurfaceLayout {
    /// Trailing nudge in device pixels. Liquid-glass stroke/highlight reads heavier on the
    /// leading edge, so layout-centered content looks slightly left without this adjustment.
    private static let opticalCenterOffsetDevicePixels: CGFloat = 16

    static var opticalCenterOffsetX: CGFloat {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        return opticalCenterOffsetDevicePixels / max(scale, 1.0)
    }
}

private struct WindowPreviewPlaceholder: View {
    let isMinimized: Bool
    let geometry: AdaptivePreviewGeometry

    var body: some View {
        NativeLiquidGlassSurface(
            cornerRadius: geometry.cornerRadius,
            nativeStyle: .clear,
            material: .hudWindow,
            blendingMode: .behindWindow,
            state: .active,
            isEmphasized: false,
            tintColor: .white,
            tintOpacity: 0.018,
            strokeOpacity: 0.12,
            strokeWidth: 0.65,
            shadowOpacity: 0.10,
            shadowRadius: 9,
            shadowYOffset: 5
        ) {
            VStack(spacing: geometry.visualSize.width < 160 ? 5 : 8) {
                Image(systemName: isMinimized ? "minus.rectangle" : "macwindow")
                    .font(.system(size: geometry.visualSize.width < 160 ? 20 : 26, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.70))

                Text(isMinimized ? "Minimized" : "Preview")
                    .font(.system(size: geometry.visualSize.width < 160 ? 9 : 10, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.64))
            }
            .frame(
                width: geometry.visualSize.width,
                height: geometry.visualSize.height,
                alignment: .center
            )
            .offset(x: PreviewGlassSurfaceLayout.opticalCenterOffsetX)
        }
    }
}

private struct WindowlessPreviewSurface: View {
    let appName: String
    let appIcon: NSImage
    let geometry: AdaptivePreviewGeometry

    var body: some View {
        NativeLiquidGlassSurface(
            cornerRadius: geometry.cornerRadius,
            nativeStyle: .clear,
            material: .hudWindow,
            blendingMode: .behindWindow,
            state: .active,
            isEmphasized: false,
            tintColor: .white,
            tintOpacity: 0.016,
            strokeOpacity: 0.11,
            strokeWidth: 0.65,
            shadowOpacity: 0.12,
            shadowRadius: 12,
            shadowYOffset: 7
        ) {
            VStack(spacing: 9) {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)
                    .cornerRadius(8)
                    .shadow(color: .black.opacity(0.10), radius: 5, x: 0, y: 2)

                VStack(spacing: 2) {
                    Text(appName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.82))
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text("No Windows")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(
                width: geometry.visualSize.width,
                height: geometry.visualSize.height,
                alignment: .center
            )
            .offset(x: PreviewGlassSurfaceLayout.opticalCenterOffsetX)
        }
        .frame(width: geometry.visualSize.width, height: geometry.visualSize.height)
    }
}
