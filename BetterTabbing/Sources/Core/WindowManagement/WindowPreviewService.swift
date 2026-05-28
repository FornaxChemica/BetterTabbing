import AppKit
import CoreGraphics
import ScreenCaptureKit

final class WindowPreviewUpdate {
    let windowID: CGWindowID
    let image: NSImage

    init(windowID: CGWindowID, image: NSImage) {
        self.windowID = windowID
        self.image = image
    }
}

/// Captures and caches lightweight window thumbnails keyed by CGWindowID.
final class WindowPreviewService: @unchecked Sendable {
    static let shared = WindowPreviewService()

    private let cache = NSCache<NSNumber, NSImage>()
    private let lock = NSLock()
    private var inFlightWindowIDs = Set<CGWindowID>()

    private static let maximumPixelSize = CGSize(width: 520, height: 320)

    private struct PreviewRequest: Sendable {
        let windowID: CGWindowID
        let sourceSize: CGSize
    }

    private init() {
        cache.countLimit = 80
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func cachedPreview(for windowID: CGWindowID) -> NSImage? {
        cache.object(forKey: cacheKey(for: windowID))
    }

    func requestPreview(for window: WindowModel) {
        requestPreviews(for: [window])
    }

    func requestPreviews(for windows: [WindowModel]) {
        var requests: [PreviewRequest] = []

        for window in windows {
            guard window.previewImage == nil else { continue }

            let windowID = window.windowID
            if let cachedImage = cachedPreview(for: windowID) {
                postPreview(cachedImage, for: windowID)
                continue
            }

            guard window.canCapturePreview else { continue }
            guard markInFlight(windowID) else { continue }

            requests.append(PreviewRequest(windowID: windowID, sourceSize: window.bounds.size))
        }

        guard !requests.isEmpty else { return }

        Task.detached(priority: .userInitiated) {
            await self.capturePreviews(for: requests)
        }
    }

    private func capturePreviews(for requests: [PreviewRequest]) async {
        guard await PermissionManager.shared.requestScreenRecordingIfNeeded() else {
            for request in requests {
                clearInFlight(request.windowID)
            }
            print("[WindowPreviewService] Screen Recording permission is required for window previews")
            return
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            let windowsByID = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })

            for request in requests {
                defer { clearInFlight(request.windowID) }

                guard let window = windowsByID[request.windowID],
                      let image = try await Self.captureWindowImage(window, sourceSize: request.sourceSize) else {
                    continue
                }

                cache.setObject(
                    image,
                    forKey: cacheKey(for: request.windowID),
                    cost: Self.cacheCost(for: image)
                )
                postPreview(image, for: request.windowID)
            }
        } catch {
            for request in requests {
                clearInFlight(request.windowID)
            }
            print("[WindowPreviewService] Failed to capture previews: \(error)")
        }
    }

    private func markInFlight(_ windowID: CGWindowID) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !inFlightWindowIDs.contains(windowID) else { return false }
        inFlightWindowIDs.insert(windowID)
        return true
    }

    private func clearInFlight(_ windowID: CGWindowID) {
        lock.lock()
        inFlightWindowIDs.remove(windowID)
        lock.unlock()
    }

    private func postPreview(_ image: NSImage, for windowID: CGWindowID) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .windowPreviewDidLoad,
                object: WindowPreviewUpdate(windowID: windowID, image: image)
            )
        }
    }

    private func cacheKey(for windowID: CGWindowID) -> NSNumber {
        NSNumber(value: UInt64(windowID))
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

        let scale = min(
            maximumPixelSize.width / sourceSize.width,
            maximumPixelSize.height / sourceSize.height,
            1
        )

        return (
            max(1, Int(sourceSize.width * scale)),
            max(1, Int(sourceSize.height * scale))
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

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        return context.makeImage()
    }
}

extension Notification.Name {
    static let windowPreviewDidLoad = Notification.Name("windowPreviewDidLoad")
}
