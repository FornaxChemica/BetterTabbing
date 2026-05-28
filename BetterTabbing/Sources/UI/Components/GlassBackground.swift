import AppKit
import SwiftUI

/// Native AppKit material surface for compositor-style overlays.
struct GlassBackground: View {
    var cornerRadius: CGFloat = 16
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active
    var isEmphasized: Bool = false
    var glassStyle: NSGlassEffectView.Style = .clear
    var tintColor: NSColor = .white
    var tintOpacity: CGFloat = 0.05
    var strokeOpacity: CGFloat = 0.08
    var strokeWidth: CGFloat = 0.6
    var shadowOpacity: CGFloat = 0.10
    var shadowRadius: CGFloat = 18
    var shadowYOffset: CGFloat = 10

    var body: some View {
        ZStack {
            LiquidGlassBackground(
                cornerRadius: cornerRadius,
                style: glassStyle,
                tintColor: tintColor.withAlphaComponent(tintOpacity)
            )

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: tintColor).opacity(tintOpacity * 0.55))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(strokeOpacity), lineWidth: strokeWidth)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, x: 0, y: shadowYOffset)
    }
}

private struct LiquidGlassBackground: NSViewRepresentable {
    let cornerRadius: CGFloat
    let style: NSGlassEffectView.Style
    let tintColor: NSColor

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSGlassEffectView) {
        view.style = style
        view.cornerRadius = cornerRadius
        view.tintColor = tintColor
    }
}
