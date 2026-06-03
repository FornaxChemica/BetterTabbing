import Foundation

enum WindowSlotOutcome: Equatable {
    case activated(slot: Int, appName: String, windowTitle: String)
    case slotVacant(Int)
    case windowUnavailable(Int)
    case moduleDisabled

    var hudTitle: String {
        switch self {
        case .activated(let slot, let appName, let windowTitle):
            let label = windowTitle.isEmpty || windowTitle == appName
                ? appName
                : "\(appName) · \(windowTitle)"
            return "Slot \(slot) · \(label)"
        case .slotVacant(let slot):
            return "Slot \(slot) is vacant"
        case .windowUnavailable(let slot):
            return "Slot \(slot) window closed"
        case .moduleDisabled:
            return "Window slots disabled"
        }
    }

    var hudDetail: String? {
        switch self {
        case .activated:
            return "⌃ plus number"
        case .slotVacant:
            return "Assign in Settings"
        case .windowUnavailable:
            return "Clear or reassign in Preferences"
        case .moduleDisabled:
            return nil
        }
    }

    var systemImageName: String {
        switch self {
        case .activated:
            return "number.square.fill"
        case .slotVacant:
            return "number.square"
        case .windowUnavailable:
            return "xmark.square"
        case .moduleDisabled:
            return "number.square"
        }
    }

    var isSuccess: Bool {
        if case .activated = self { return true }
        return false
    }
}
