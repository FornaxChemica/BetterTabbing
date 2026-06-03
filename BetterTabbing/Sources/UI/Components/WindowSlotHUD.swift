import AppKit
import SwiftUI

@MainActor
final class WindowSlotHUD {
    static let shared = WindowSlotHUD()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private let displayDuration: TimeInterval = 1.35

    private init() {}

    func present(outcome: WindowSlotOutcome) {
        guard outcome != .moduleDisabled else { return }

        hideTask?.cancel()

        let rootView = WindowSlotHUDView(outcome: outcome)
        let hostingController = NSHostingController(rootView: rootView)

        let panel = self.panel ?? makePanel(hostingController: hostingController)
        panel.contentViewController = hostingController
        self.panel = panel

        hostingController.view.layoutSubtreeIfNeeded()
        let fittingSize = hostingController.view.fittingSize

        panel.alphaValue = 0
        positionPanel(panel, fittingSize: fittingSize)

        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            panel.animator().alphaValue = 1
        }

        hideTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.displayDuration))
            guard let panel = self.panel else { return }

            await withCheckedContinuation { continuation in
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.18
                    panel.animator().alphaValue = 0
                }, completionHandler: {
                    continuation.resume()
                })
            }

            panel.orderOut(nil)
            self.hideTask = nil
        }
    }

    private func makePanel(hostingController: NSHostingController<WindowSlotHUDView>) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentViewController = hostingController
        return panel
    }

    private func positionPanel(_ panel: NSPanel, fittingSize: NSSize) {
        guard let screen = screenForPresentation() else { return }

        let panelSize = NSSize(
            width: max(fittingSize.width, 1),
            height: max(fittingSize.height, 1)
        )
        let visibleFrame = screen.visibleFrame
        let origin = CGPoint(
            x: screen.frame.midX - panelSize.width / 2,
            y: visibleFrame.maxY - panelSize.height - 18
        )

        panel.setFrame(CGRect(origin: origin, size: panelSize), display: true)
    }

    private func screenForPresentation() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}

private struct WindowSlotHUDView: View {
    let outcome: WindowSlotOutcome

    private var iconTint: Color {
        if outcome.isSuccess {
            Color.primary.opacity(0.82)
        } else {
            Color.secondary.opacity(0.82)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: outcome.systemImageName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(iconTint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.hudTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let detail = outcome.hudDetail {
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            GlassBackground(
                cornerRadius: 14,
                tintOpacity: 0.05,
                strokeOpacity: 0.10,
                shadowOpacity: 0.14,
                shadowRadius: 14,
                shadowYOffset: 6
            )
        )
        .compositingGroup()
        .padding(10)
        .fixedSize(horizontal: true, vertical: true)
    }
}
