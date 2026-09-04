import AppKit
import SwiftUI

/// Compact command-strip chip that opens the Stay Awake panel popover.
struct StayAwakeChipView: View {
    @ObservedObject private var manager = KeepAwakeManager.shared
    @State private var isPopoverPresented = false

    private var isAgentMode: Bool {
        manager.isActive && manager.activeDuration == .whileAgentsActive
    }

    var body: some View {
        Button {
            isPopoverPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: chipSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .symbolEffect(.pulse, isActive: manager.isActive && !manager.isPausedForHeat)
                Text(chipLabel)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
            }
            .foregroundStyle(manager.isActive ? Color.primary : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(manager.isActive ? Color.primary.opacity(0.12) : Color.white.opacity(0.05))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(manager.isActive ? 0.18 : 0.08), lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            StayAwakeControlsView(compact: true, showsChrome: true)
                .padding(14)
                .frame(width: 320)
        }
    }

    private var chipSymbol: String {
        if manager.isPausedForHeat { return "thermometer.medium" }
        if isAgentMode { return "brain.head.profile" }
        if manager.lidClosedStayAwakeEnabled, manager.isActive {
            return "moon.slash"
        }
        return manager.isActive ? "cup.and.saucer.fill" : "cup.and.saucer"
    }

    private var chipLabel: String {
        if manager.isActive {
            return manager.countdownText
        }
        return "Awake"
    }
}
