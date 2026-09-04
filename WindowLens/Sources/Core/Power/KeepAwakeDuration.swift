import Foundation

/// Fixed Stay Awake session presets (no custom minute spinner).
enum KeepAwakeDuration: String, Codable, CaseIterable, Identifiable, Sendable {
    case minutes15
    case minutes30
    case hour1
    case hours2
    case hours4
    case hours8
    case indefinitely
    case whileAgentsActive

    var id: String { rawValue }

    static var timedPresets: [KeepAwakeDuration] {
        [.minutes15, .minutes30, .hour1, .hours2, .hours4, .hours8, .indefinitely]
    }

    var displayName: String {
        switch self {
        case .minutes15: return "15 minutes"
        case .minutes30: return "30 minutes"
        case .hour1: return "1 hour"
        case .hours2: return "2 hours"
        case .hours4: return "4 hours"
        case .hours8: return "8 hours"
        case .indefinitely: return "Forever"
        case .whileAgentsActive: return "Until AI agents finish"
        }
    }

    var shortLabel: String {
        switch self {
        case .minutes15: return "15m"
        case .minutes30: return "30m"
        case .hour1: return "1h"
        case .hours2: return "2h"
        case .hours4: return "4h"
        case .hours8: return "8h"
        case .indefinitely: return "∞"
        case .whileAgentsActive: return "AI"
        }
    }

    var symbolName: String {
        switch self {
        case .minutes15: return "clock"
        case .minutes30: return "clock.badge.checkmark"
        case .hour1: return "clock.fill"
        case .hours2: return "hourglass"
        case .hours4: return "moon.stars"
        case .hours8: return "moon.fill"
        case .indefinitely: return "infinity"
        case .whileAgentsActive: return "brain.head.profile"
        }
    }

    var timeInterval: TimeInterval? {
        switch self {
        case .minutes15: return 15 * 60
        case .minutes30: return 30 * 60
        case .hour1: return 60 * 60
        case .hours2: return 2 * 60 * 60
        case .hours4: return 4 * 60 * 60
        case .hours8: return 8 * 60 * 60
        case .indefinitely, .whileAgentsActive: return nil
        }
    }

    var followsAgents: Bool {
        self == .whileAgentsActive
    }
}
