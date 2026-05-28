import AppKit
import CoreGraphics
import ScreenCaptureKit

final class WindowPreviewUpdate {
    let windowID: CGWindowID
    let ownerPID: pid_t?
    let title: String
    let bounds: CGRect
    let image: NSImage

    init(windowID: CGWindowID, ownerPID: pid_t?, title: String, bounds: CGRect, image: NSImage) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.title = title
        self.bounds = bounds
        self.image = image
    }
}

/// Captures and caches lightweight window thumbnails keyed by PID, CGWindowID, title, and bounds.
final class WindowPreviewService: @unchecked Sendable {
    static let shared = WindowPreviewService()

    private let cache = NSCache<NSString, NSImage>()
    private let lock = NSLock()
    private var inFlightPreviewKeys = Set<String>()

    private let isPreviewDebugLoggingEnabled = true
    private static let maximumPixelSize = CGSize(width: 1400, height: 900)

    private struct PreviewRequest: Sendable {
        let windowID: CGWindowID
        let ownerPID: pid_t?
        let appName: String?
        let title: String
        let bounds: CGRect
        let cacheKey: String

        var sourceSize: CGSize { bounds.size }
    }

    private init() {
        cache.countLimit = 80
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func cachedPreview(
        for windowID: CGWindowID,
        ownerPID: pid_t? = nil,
        title: String? = nil,
        bounds: CGRect = .zero
    ) -> NSImage? {
        let key = cacheKey(
            for: windowID,
            ownerPID: ownerPID,
            title: title,
            bounds: bounds
        )
        let image = cache.object(forKey: key as NSString)
        if image != nil {
            log("cache hit key=\(key)")
        }
        return image
    }

    func requestPreview(for window: WindowModel, ownerPID: pid_t? = nil, appName: String? = nil) {
        requestPreviews(for: [window], ownerPID: ownerPID, appName: appName)
    }

    func requestPreviews(for windows: [WindowModel], ownerPID: pid_t? = nil, appName: String? = nil) {
        var requests: [PreviewRequest] = []

        for window in windows {
            let windowID = window.windowID

            let key = cacheKey(
                for: windowID,
                ownerPID: ownerPID,
                title: window.title,
                bounds: window.bounds
            )

            if let cachedImage = cachedPreview(
                for: windowID,
                ownerPID: ownerPID,
                title: window.title,
                bounds: window.bounds
            ) {
                log("posting cached preview id=\(windowID) title=\(window.title)")
                postPreview(cachedImage, for: PreviewRequest(
                    windowID: windowID,
                    ownerPID: ownerPID,
                    appName: appName,
                    title: window.title,
                    bounds: window.bounds,
                    cacheKey: key
                ))
                continue
            }

            if window.previewImage != nil {
                log("recapturing existing preview without keyed cache id=\(windowID) pid=\(ownerPID.map(String.init) ?? "unknown") title=\(window.title)")
            }

            log("cache miss id=\(windowID) pid=\(ownerPID.map(String.init) ?? "unknown") app=\(appName ?? "unknown") title=\(window.title) capture=\(window.canCapturePreview) bounds=\(Self.describe(window.bounds))")

            guard window.canCapturePreview else { continue }
            guard markInFlight(key) else {
                log("skip in-flight id=\(windowID) title=\(window.title)")
                continue
            }

            requests.append(PreviewRequest(
                windowID: windowID,
                ownerPID: ownerPID,
                appName: appName,
                title: window.title,
                bounds: window.bounds,
                cacheKey: key
            ))
        }

        guard !requests.isEmpty else { return }

        log("queued \(requests.count) preview request(s): \(requests.map { String($0.windowID) }.joined(separator: ","))")
        Task.detached(priority: .userInitiated) {
            await self.capturePreviews(for: requests)
        }
    }

    private func capturePreviews(for requests: [PreviewRequest]) async {
        guard await PermissionManager.shared.requestScreenRecordingIfNeeded() else {
            for request in requests {
                clearInFlight(request.cacheKey)
            }
            log("Screen Recording permission is required for window previews")
            return
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            let windowsByID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
            log("ScreenCaptureKit returned \(content.windows.count) window(s), \(content.displays.count) display(s), \(content.applications.count) app(s)")

            for request in requests {
                defer { clearInFlight(request.cacheKey) }

                guard let window = matchWindow(for: request, windowsByID: windowsByID, allWindows: content.windows) else {
                    log("no SCWindow match for AX id=\(request.windowID) pid=\(request.ownerPID.map(String.init) ?? "unknown") app=\(request.appName ?? "unknown") title=\(request.title) bounds=\(Self.describe(request.bounds)); candidates=\(candidateSummary(for: request, in: content.windows))")
                    continue
                }

                do {
                    guard let image = try await Self.captureWindowImage(window, sourceSize: request.sourceSize) else {
                        log("capture returned no image for AX id=\(request.windowID) matchedSC id=\(window.windowID) title=\(window.title ?? "untitled")")
                        continue
                    }

                    log("captured preview AX id=\(request.windowID) SC id=\(window.windowID) image=\(Int(image.size.width))x\(Int(image.size.height)) title=\(request.title)")
                    cache.setObject(
                        image,
                        forKey: request.cacheKey as NSString,
                        cost: Self.cacheCost(for: image)
                    )
                    postPreview(image, for: request)
                } catch {
                    log("capture failed AX id=\(request.windowID) matchedSC id=\(window.windowID) title=\(request.title): \(error)")
                }
            }
        } catch {
            for request in requests {
                clearInFlight(request.cacheKey)
            }
            log("failed to fetch shareable content: \(error)")
        }
    }

    private func matchWindow(
        for request: PreviewRequest,
        windowsByID: [CGWindowID: SCWindow],
        allWindows: [SCWindow]
    ) -> SCWindow? {
        if let directMatch = windowsByID[request.windowID] {
            let directPID = directMatch.owningApplication?.processID
            if request.ownerPID == nil || directPID == request.ownerPID {
                if Self.identityMatches(window: directMatch, request: request) {
                    log("matched by CGWindowID AX id=\(request.windowID) SC id=\(directMatch.windowID) pid=\(directPID.map(String.init) ?? "unknown") title=\(directMatch.title ?? "untitled")")
                    return directMatch
                }

                log("ignored CGWindowID match with stale identity AX id=\(request.windowID) SC id=\(directMatch.windowID) requestedTitle=\(request.title) scTitle=\(directMatch.title ?? "untitled") requestedBounds=\(Self.describe(request.bounds)) scFrame=\(Self.describe(directMatch.frame))")
            }

            log("ignored CGWindowID match with wrong pid AX id=\(request.windowID) requestedPID=\(request.ownerPID.map(String.init) ?? "unknown") scPID=\(directPID.map(String.init) ?? "unknown") title=\(directMatch.title ?? "untitled")")
        }

        guard let ownerPID = request.ownerPID else { return nil }

        let pidCandidates = allWindows.filter { window in
            window.owningApplication?.processID == ownerPID && window.isOnScreen
        }
        let layerCandidates = pidCandidates.filter { $0.windowLayer == 0 }
        let candidates = layerCandidates.isEmpty ? pidCandidates : layerCandidates
        guard !candidates.isEmpty else { return nil }

        let rankedCandidates = candidates
            .map { window in (window, Self.matchScore(window: window, request: request)) }
            .sorted { lhs, rhs in lhs.1 < rhs.1 }

        guard let bestMatch = rankedCandidates.first else { return nil }
        let hasUsableGeometry = request.bounds.width > 1 && request.bounds.height > 1
        let maximumAcceptableScore: CGFloat = hasUsableGeometry ? 80 : 45
        guard bestMatch.1 <= maximumAcceptableScore else {
            log("rejected weak fallback match AX id=\(request.windowID) bestSC id=\(bestMatch.0.windowID) score=\(Int(bestMatch.1)) pid=\(ownerPID) title=\(bestMatch.0.title ?? "untitled")")
            return nil
        }

        log("fallback matched AX id=\(request.windowID) to SC id=\(bestMatch.0.windowID) score=\(Int(bestMatch.1)) pid=\(ownerPID) title=\(bestMatch.0.title ?? "untitled")")
        return bestMatch.0
    }

    private static func identityMatches(window: SCWindow, request: PreviewRequest) -> Bool {
        let requestTitle = normalizedTitle(request.title)
        let windowTitle = normalizedTitle(window.title ?? "")
        if !requestTitle.isEmpty && !windowTitle.isEmpty && requestTitle != windowTitle {
            return false
        }

        guard hasReliableBounds(request.bounds), hasReliableBounds(window.frame) else {
            return true
        }

        return abs(window.frame.minX - request.bounds.minX) <= 2
            && abs(window.frame.minY - request.bounds.minY) <= 2
            && abs(window.frame.width - request.bounds.width) <= 2
            && abs(window.frame.height - request.bounds.height) <= 2
    }

    private func candidateSummary(for request: PreviewRequest, in windows: [SCWindow]) -> String {
        let candidates = windows
            .filter { window in
                guard let ownerPID = request.ownerPID else { return true }
                return window.owningApplication?.processID == ownerPID
            }
            .prefix(6)
            .map { window in
                "id=\(window.windowID) layer=\(window.windowLayer) onScreen=\(window.isOnScreen) title=\(window.title ?? "untitled") frame=\(Self.describe(window.frame))"
            }

        let summary = candidates.joined(separator: " | ")
        return summary.isEmpty ? "none" : summary
    }

    private static func matchScore(window: SCWindow, request: PreviewRequest) -> CGFloat {
        var score: CGFloat = 0

        let requestTitle = normalizedTitle(request.title)
        let windowTitle = normalizedTitle(window.title ?? "")
        if !requestTitle.isEmpty {
            if windowTitle == requestTitle {
                score += 0
            } else if windowTitle.contains(requestTitle) || requestTitle.contains(windowTitle) {
                score += 4
            } else {
                score += 25
            }
        }

        let frame = window.frame
        score += min(abs(frame.width - request.bounds.width) / 10, 40)
        score += min(abs(frame.height - request.bounds.height) / 10, 40)
        score += min(abs(frame.minX - request.bounds.minX) / 80, 20)
        score += min(abs(frame.minY - request.bounds.minY) / 80, 20)
        score += CGFloat(abs(window.windowLayer)) * 20

        return score
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func hasReliableBounds(_ bounds: CGRect) -> Bool {
        bounds.width > 16 && bounds.height > 16
    }

    private static func describe(_ rect: CGRect) -> String {
        "x=\(Int(rect.origin.x)) y=\(Int(rect.origin.y)) w=\(Int(rect.width)) h=\(Int(rect.height))"
    }

    private func log(_ message: String) {
        guard isPreviewDebugLoggingEnabled else { return }
        print("[WindowPreviewService][debug] \(message)")
    }

    private func markInFlight(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !inFlightPreviewKeys.contains(key) else { return false }
        inFlightPreviewKeys.insert(key)
        return true
    }

    private func clearInFlight(_ key: String) {
        lock.lock()
        inFlightPreviewKeys.remove(key)
        lock.unlock()
    }

    private func postPreview(_ image: NSImage, for request: PreviewRequest) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .windowPreviewDidLoad,
                object: WindowPreviewUpdate(
                    windowID: request.windowID,
                    ownerPID: request.ownerPID,
                    title: request.title,
                    bounds: request.bounds,
                    image: image
                )
            )
        }
    }

    private func cacheKey(
        for windowID: CGWindowID,
        ownerPID: pid_t?,
        title: String?,
        bounds: CGRect
    ) -> String {
        Self.cacheKey(for: windowID, ownerPID: ownerPID, title: title, bounds: bounds)
    }

    private static func cacheKey(
        for windowID: CGWindowID,
        ownerPID: pid_t?,
        title: String?,
        bounds: CGRect
    ) -> String {
        let normalizedTitle = normalizedTitle(title ?? "")
        let rectKey = [
            Int(bounds.origin.x.rounded()),
            Int(bounds.origin.y.rounded()),
            Int(bounds.width.rounded()),
            Int(bounds.height.rounded())
        ]
            .map(String.init)
            .joined(separator: "x")
        return "\(ownerPID ?? -1):\(windowID):\(normalizedTitle):\(rectKey)"
    }

    private static func cacheCost(for image: NSImage) -> Int {
        max(1, Int(image.size.width * image.size.height * 4))
    }

    private static func captureWindowImage(_ window: SCWindow, sourceSize: CGSize) async throws -> NSImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCScreenshotConfiguration()
        let outputSize = pixelSize(for: sourceSize)
        configuration.width = outputSize.width
        configuration.height = outputSize.height
        configuration.ignoreShadows = true
        configuration.includeChildWindows = true
        configuration.showsCursor = false

        let output = try await SCScreenshotManager.captureScreenshot(
            contentFilter: filter,
            configuration: configuration
        )

        guard let image = output.sdrImage ?? output.hdrImage else { return nil }
        let thumbnail = downsample(image) ?? image
        return NSImage(
            cgImage: thumbnail,
            size: NSSize(width: CGFloat(thumbnail.width), height: CGFloat(thumbnail.height))
        )
    }

    private static func pixelSize(for sourceSize: CGSize) -> (width: Int, height: Int) {
        guard sourceSize.width > 1, sourceSize.height > 1 else {
            return (Int(maximumPixelSize.width), Int(maximumPixelSize.height))
        }

        let backingScale = max(NSScreen.screens.map(\.backingScaleFactor).max() ?? 2.0, 1.0)
        let scale = min(
            maximumPixelSize.width / sourceSize.width,
            maximumPixelSize.height / sourceSize.height,
            backingScale
        )

        return (
            max(1, Int((sourceSize.width * scale).rounded(.up))),
            max(1, Int((sourceSize.height * scale).rounded(.up)))
        )
    }

    private static func downsample(_ image: CGImage) -> CGImage? {
        let sourceSize = CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
        guard sourceSize.width > maximumPixelSize.width || sourceSize.height > maximumPixelSize.height else {
            return image
        }

        let scale = min(
            maximumPixelSize.width / sourceSize.width,
            maximumPixelSize.height / sourceSize.height
        )
        let pixelWidth = max(1, Int(sourceSize.width * scale))
        let pixelHeight = max(1, Int(sourceSize.height * scale))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        return context.makeImage()
    }
}

extension Notification.Name {
    static let windowPreviewDidLoad = Notification.Name("windowPreviewDidLoad")
}
