import AppKit
import CoreGraphics

struct WindowModel: Identifiable, Hashable {
    let id: String
    let windowID: CGWindowID
    let title: String
    let bounds: CGRect
    let isMinimized: Bool
    let isOnScreen: Bool
    let spaceID: Int?
    let previewIdentity: PreviewIdentity
    var previewImage: NSImage?

    // Extended metadata
    var subtitle: String?

    init(
        windowID: CGWindowID,
        title: String,
        bounds: CGRect = .zero,
        isMinimized: Bool = false,
        isOnScreen: Bool = true,
        spaceID: Int? = nil,
        ownerPID: pid_t? = nil,
        bundleIdentifier: String? = nil,
        axIndex: Int? = nil,
        hasReliableWindowID: Bool = true,
        previewImage: NSImage? = nil,
        subtitle: String? = nil
    ) {
        let identity = PreviewIdentity(
            ownerPID: ownerPID,
            bundleIdentifier: bundleIdentifier,
            cgWindowID: windowID,
            axIndex: axIndex,
            title: title,
            bounds: bounds,
            hasReliableCGWindowID: hasReliableWindowID
        )
        self.id = identity.surfaceID
        self.windowID = windowID
        self.title = title
        self.bounds = bounds
        self.isMinimized = isMinimized
        self.isOnScreen = isOnScreen
        self.spaceID = spaceID
        self.previewIdentity = identity
        self.previewImage = previewImage
        self.subtitle = subtitle
    }

    init(from info: WindowInfo, previewImage: NSImage? = nil) {
        let title = info.windowName ?? info.ownerName
        let identity = PreviewIdentity(
            ownerPID: info.ownerPID,
            bundleIdentifier: info.ownerBundleIdentifier,
            cgWindowID: info.windowID,
            axIndex: info.axIndex,
            title: title,
            bounds: info.bounds,
            hasReliableCGWindowID: info.hasReliableWindowID
        )
        self.id = identity.surfaceID
        self.windowID = info.windowID
        self.title = title
        self.bounds = info.bounds
        self.isMinimized = info.isMinimized
        self.isOnScreen = info.isOnScreen
        self.spaceID = info.spaceID
        self.previewIdentity = identity
        self.previewImage = previewImage
        self.subtitle = nil
    }

    var canCapturePreview: Bool {
        !isMinimized && bounds.width > 1 && bounds.height > 1
    }

    var isWindowlessPlaceholder: Bool {
        !previewIdentity.hasReliableCGWindowID
            && bounds == .zero
            && !isMinimized
            && !isOnScreen
            && (subtitle == "No Windows" || PreviewIdentity.normalizedTitle(title) == "no windows")
    }

    /// Stable identity for switcher carousel rows across re-enumeration (CGWindowID can resolve after first pass).
    var carouselItemID: String {
        let normalizedTitle = PreviewIdentity.normalizedTitle(title)
        if let ownerPID = previewIdentity.ownerPID, let axIndex = previewIdentity.axIndex {
            return "carousel:\(ownerPID):\(axIndex):\(normalizedTitle)"
        }
        if let ownerPID = previewIdentity.ownerPID, !normalizedTitle.isEmpty {
            return "carousel:\(ownerPID):\(normalizedTitle)"
        }
        return previewIdentity.surfaceID
    }

    func compositorIdentity(ownerPID: pid_t) -> String {
        previewIdentity.withOwner(pid: ownerPID, bundleIdentifier: nil).surfaceID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: WindowModel, rhs: WindowModel) -> Bool {
        lhs.id == rhs.id
    }

    /// Replaces the window list with a fresh enumeration while keeping thumbnails already shown in the switcher.
    static func mergedPreservingPreviews(
        fresh: [WindowModel],
        existing: [WindowModel]
    ) -> [WindowModel] {
        fresh.map { window in
            var merged = window

            if merged.isWindowlessPlaceholder {
                merged.previewImage = nil
                return merged
            }

            if merged.previewImage == nil,
               let existingWindow = existing.first(where: { merged.previewIdentity.matches($0.previewIdentity) }),
               let previewImage = existingWindow.previewImage {
                merged.previewImage = previewImage
            }

            if merged.previewImage == nil,
               let ownerPID = merged.previewIdentity.ownerPID {
                let normalizedTitle = PreviewIdentity.normalizedTitle(merged.title)
                if let existingWindow = existing.first(where: { window in
                    window.previewIdentity.ownerPID == ownerPID
                        && PreviewIdentity.normalizedTitle(window.title) == normalizedTitle
                }), let previewImage = existingWindow.previewImage {
                    merged.previewImage = previewImage
                }
            }

            if merged.previewImage == nil,
               let cachedPreview = WindowPreviewService.shared.cachedPreview(for: merged.previewIdentity) {
                merged.previewImage = cachedPreview
            }

            return merged
        }
    }
}

struct WindowInfo {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerBundleIdentifier: String?
    let axIndex: Int?
    let ownerName: String
    let windowName: String?
    let bounds: CGRect
    let isOnScreen: Bool
    let isMinimized: Bool
    let isHidden: Bool
    let isMain: Bool
    let spaceID: Int?
    let hasReliableWindowID: Bool
}
