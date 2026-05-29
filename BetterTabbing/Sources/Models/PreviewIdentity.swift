import CoreGraphics
import Foundation

struct PreviewIdentity: Hashable, Sendable {
    let ownerPID: pid_t?
    let bundleIdentifier: String?
    let cgWindowID: CGWindowID
    let axIndex: Int?
    let normalizedTitle: String
    let boundsBucket: String
    let hasReliableCGWindowID: Bool

    init(
        ownerPID: pid_t?,
        bundleIdentifier: String?,
        cgWindowID: CGWindowID,
        axIndex: Int? = nil,
        title: String,
        bounds: CGRect,
        hasReliableCGWindowID: Bool = true
    ) {
        self.ownerPID = ownerPID
        self.bundleIdentifier = bundleIdentifier
        self.cgWindowID = cgWindowID
        self.axIndex = axIndex
        self.normalizedTitle = Self.normalizedTitle(title)
        self.boundsBucket = Self.boundsBucket(bounds)
        self.hasReliableCGWindowID = hasReliableCGWindowID && cgWindowID != 0
    }

    var stableKey: String {
        cacheKeys.first ?? "window:\(cgWindowID)"
    }

    var surfaceID: String {
        stableKey
    }

    var diskCacheFileName: String {
        "\(Self.stableHashHex(stableKey)).jpg"
    }

    var cacheKeys: [String] {
        var keys: [String] = []

        if hasReliableCGWindowID {
            if let ownerPID {
                keys.append("pid:\(ownerPID):wid:\(cgWindowID)")
            }
            if let bundleIdentifier, !bundleIdentifier.isEmpty {
                keys.append("bundle:\(bundleIdentifier):wid:\(cgWindowID)")
            }
        }

        if let ownerPID, !normalizedTitle.isEmpty, boundsBucket != Self.emptyBoundsBucket {
            keys.append("pid:\(ownerPID):title:\(normalizedTitle):bounds:\(boundsBucket)")
        }

        if let ownerPID, let axIndex, !normalizedTitle.isEmpty {
            keys.append("pid:\(ownerPID):ax:\(axIndex):title:\(normalizedTitle)")
        }

        if keys.isEmpty {
            keys.append("wid:\(cgWindowID)")
        }

        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    func matches(_ other: PreviewIdentity) -> Bool {
        if hasReliableCGWindowID,
           other.hasReliableCGWindowID,
           cgWindowID == other.cgWindowID,
           ownerOrBundleMatches(other) {
            return true
        }

        return !Set(cacheKeys).isDisjoint(with: other.cacheKeys)
    }

    func withOwner(pid: pid_t, bundleIdentifier: String?) -> PreviewIdentity {
        PreviewIdentity(
            ownerPID: ownerPID ?? pid,
            bundleIdentifier: self.bundleIdentifier ?? bundleIdentifier,
            cgWindowID: cgWindowID,
            axIndex: axIndex,
            title: normalizedTitle,
            bounds: boundsFromBucket(boundsBucket),
            hasReliableCGWindowID: hasReliableCGWindowID
        )
    }

    static func pseudoWindowID(ownerPID: pid_t, axIndex: Int, title: String?, bounds: CGRect) -> CGWindowID {
        let key = "\(ownerPID):\(axIndex):\(normalizedTitle(title ?? "")):\(boundsBucket(bounds))"
        let hash = stableHash(key) | 0x8000_0000
        return CGWindowID(hash == 0 ? 0x8000_0001 : hash)
    }

    static func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func boundsBucket(_ bounds: CGRect) -> String {
        guard bounds.width > 1, bounds.height > 1 else {
            return emptyBoundsBucket
        }

        let bucket: CGFloat = 24
        let values = [
            rounded(bounds.origin.x, bucket: bucket),
            rounded(bounds.origin.y, bucket: bucket),
            rounded(bounds.width, bucket: bucket),
            rounded(bounds.height, bucket: bucket)
        ]
        return values.map(String.init).joined(separator: "x")
    }

    static func stableHashHex(_ string: String) -> String {
        String(format: "%08x", stableHash(string))
    }

    private static let emptyBoundsBucket = "unknown"

    private func ownerOrBundleMatches(_ other: PreviewIdentity) -> Bool {
        if let ownerPID, let otherPID = other.ownerPID, ownerPID == otherPID {
            return true
        }

        if let bundleIdentifier,
           let otherBundleIdentifier = other.bundleIdentifier,
           !bundleIdentifier.isEmpty,
           bundleIdentifier == otherBundleIdentifier {
            return true
        }

        return ownerPID == nil && bundleIdentifier == nil
            || other.ownerPID == nil && other.bundleIdentifier == nil
    }

    private static func rounded(_ value: CGFloat, bucket: CGFloat) -> Int {
        Int((value / bucket).rounded() * bucket)
    }

    private static func stableHash(_ string: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }

    private func boundsFromBucket(_ bucket: String) -> CGRect {
        let values = bucket
            .split(separator: "x")
            .compactMap { Double($0) }

        guard values.count == 4 else {
            return .zero
        }

        return CGRect(
            x: values[0],
            y: values[1],
            width: values[2],
            height: values[3]
        )
    }
}
