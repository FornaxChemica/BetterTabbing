import SwiftUI

struct PermissionOnboardingView: View {
    @StateObject private var viewModel = PermissionOnboardingViewModel()
    @State private var hasCompleted = false

    let onComplete: () -> Void

    var body: some View {
        NativeLiquidGlassSurface(
            cornerRadius: 24,
            nativeStyle: .regular,
            material: .hudWindow,
            tintOpacity: 0.026,
            strokeOpacity: 0.11,
            strokeWidth: 0.7,
            shadowOpacity: 0.18,
            shadowRadius: 24,
            shadowYOffset: 14
        ) {
            VStack(alignment: .leading, spacing: 20) {
                header

                VStack(spacing: 10) {
                    ForEach(viewModel.items) { item in
                        PermissionRowView(item: item) {
                            viewModel.grant(item.permission)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
            }
            .padding(24)
            .frame(width: 420)
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: viewModel.items)
        .task {
            await viewModel.refreshNow()
            completeIfReady()
        }
        .onChange(of: viewModel.allGranted) { _, allGranted in
            guard allGranted else { return }
            completeIfReady()
        }
    }

    private func completeIfReady() {
        guard viewModel.allGranted, !hasCompleted else { return }
        hasCompleted = true

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            onComplete()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 6) {
                Text("WindowLens needs a few permissions")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("WindowLens uses these permissions only to observe shortcuts, inspect windows, and render local previews on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PermissionRowView: View {
    let item: PermissionOnboardingViewModel.PermissionItem
    let grant: () -> Void

    var body: some View {
        NativeLiquidGlassSurface(
            cornerRadius: 14,
            nativeStyle: .clear,
            material: .popover,
            tintOpacity: 0.018,
            strokeOpacity: 0.075,
            shadowOpacity: 0.035,
            shadowRadius: 8,
            shadowYOffset: 4
        ) {
            HStack(spacing: 12) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(item.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)

                trailingControl
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch item.state {
        case .idle:
            Button("Grant", action: grant)
                .buttonStyle(.borderedProminent)
        case .waiting:
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting...")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 82, alignment: .trailing)
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: item.state)
                .frame(width: 82, alignment: .trailing)
        }
    }

    private var iconColor: Color {
        item.state == .granted ? .green : .secondary
    }
}

struct PermissionReadyView: View {
    let onDismiss: () -> Void

    var body: some View {
        NativeLiquidGlassSurface(
            cornerRadius: 24,
            nativeStyle: .regular,
            material: .hudWindow,
            tintOpacity: 0.024,
            strokeOpacity: 0.10,
            strokeWidth: 0.7,
            shadowOpacity: 0.18,
            shadowRadius: 22,
            shadowYOffset: 12
        ) {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce)

                VStack(spacing: 5) {
                    Text("WindowLens is ready")
                        .font(.title3.weight(.semibold))

                    Text("All permissions are granted. Option-Tab is active.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button("Done", action: onDismiss)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
            .padding(24)
            .frame(width: 360)
        }
        .task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            await MainActor.run {
                onDismiss()
            }
        }
    }
}
