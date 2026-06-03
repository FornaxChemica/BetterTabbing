import SwiftUI

struct WindowSlotBadge: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .frame(minWidth: 16, minHeight: 16)
            .padding(.horizontal, label.count > 1 ? 3 : 0)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.15))
            )
    }

    static func railLabel(for slots: [Int]) -> String? {
        guard let first = slots.first else { return nil }
        if slots.count == 1 {
            return "\(first)"
        }
        return "\(first)+\(slots.count - 1)"
    }
}
