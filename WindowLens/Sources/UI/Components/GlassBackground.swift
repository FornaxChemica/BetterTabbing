import AppKit
import SwiftUI

/// Frosted panel matching the Settings window — `.thinMaterial` blur with a light dim overlay.
struct FrostedPanelBackground: View {
    var cornerRadius: CGFloat = 14
    var dimOpacity: CGFloat = 0.09
    var strokeOpacity: CGFloat = 0.14
    var strokeWidth: CGFloat = 0.5
    var shadowOpacity: CGFloat = 0.14
    var shadowRadius: CGFloat = 14
    var shadowYOffset: CGFloat = 8

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.thinMaterial)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(dimOpacity))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(strokeOpacity), lineWidth: strokeWidth)
        }
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, x: 0, y: shadowYOffset)
    }
}

/// Native AppKit material surface for compositor-style overlays.
struct GlassBackground: View {
    enum NativeStyle {
        case clear
        case regular
    }

    var cornerRadius: CGFloat = 16
    var nativeStyle: NativeStyle = .clear
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
        NativeLiquidGlassSurface(
            cornerRadius: cornerRadius,
            nativeStyle: nativeStyle,
            material: material,
            blendingMode: blendingMode,
            state: state,
            isEmphasized: isEmphasized,
            glassStyle: glassStyle,
            tintColor: tintColor,
            tintOpacity: tintOpacity,
            strokeOpacity: strokeOpacity,
            strokeWidth: strokeWidth,
            shadowOpacity: shadowOpacity,
            shadowRadius: shadowRadius,
            shadowYOffset: shadowYOffset
        ) {
            Color.clear
        }
    }
}

struct NativeLiquidGlassSurface<Content: View>: View {
    let cornerRadius: CGFloat
    var nativeStyle: GlassBackground.NativeStyle = .clear
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
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            content()
                .glassEffect(nativeGlass, in: .rect(cornerRadius: cornerRadius))
                .overlay(nativeHighlight)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, x: 0, y: shadowYOffset)
        } else {
            AppKitGlassBackground(
                cornerRadius: cornerRadius,
                material: material,
                blendingMode: blendingMode,
                state: state,
                isEmphasized: isEmphasized,
                glassStyle: glassStyle,
                tintColor: tintColor,
                tintOpacity: tintOpacity,
                strokeOpacity: strokeOpacity,
                strokeWidth: strokeWidth,
                shadowOpacity: shadowOpacity,
                shadowRadius: shadowRadius,
                shadowYOffset: shadowYOffset,
                content: content
            )
        }
    }

    @available(macOS 26.0, *)
    private var nativeGlass: Glass {
        switch nativeStyle {
        case .clear:
            return .clear
        case .regular:
            return .regular
        }
    }

    private var nativeHighlight: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(Color.white.opacity(strokeOpacity), lineWidth: strokeWidth)
    }
}

private struct AppKitGlassBackground<Content: View>: View {
    let cornerRadius: CGFloat
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let state: NSVisualEffectView.State
    let isEmphasized: Bool
    let glassStyle: NSGlassEffectView.Style
    let tintColor: NSColor
    let tintOpacity: CGFloat
    let strokeOpacity: CGFloat
    let strokeWidth: CGFloat
    let shadowOpacity: CGFloat
    let shadowRadius: CGFloat
    let shadowYOffset: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            VisualEffectBackground(
                cornerRadius: cornerRadius,
                material: material,
                blendingMode: blendingMode,
                state: state,
                isEmphasized: isEmphasized
            )

            LiquidGlassBackground(
                cornerRadius: cornerRadius,
                style: glassStyle,
                tintColor: tintColor.withAlphaComponent(tintOpacity)
            )

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: tintColor).opacity(tintOpacity * 0.55))

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(strokeOpacity), lineWidth: strokeWidth)

            content()
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, x: 0, y: shadowYOffset)
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    let cornerRadius: CGFloat
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let state: NSVisualEffectView.State
    let isEmphasized: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = isEmphasized
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
    }
}

private struct LiquidGlassBackground: NSViewRepresentable {
    let cornerRadius: CGFloat
    let style: NSGlassEffectView.Style
    let tintColor: NSColor

    func makeNSView(context: Context) -> NSView {
        guard #available(macOS 26.0, *) else {
            return NSView()
        }

        let view = NSGlassEffectView()
        configureGlassView(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard #available(macOS 26.0, *),
              let glassView = nsView as? NSGlassEffectView else {
            return
        }

        configureGlassView(glassView)
    }

    @available(macOS 26.0, *)
    private func configureGlassView(_ view: NSGlassEffectView) {
        view.style = style
        view.cornerRadius = cornerRadius
        view.tintColor = tintColor
    }
}
