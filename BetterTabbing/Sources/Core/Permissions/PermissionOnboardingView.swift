import SwiftUI

struct PermissionOnboardingView: View {
    @StateObject private var viewModel = PermissionOnboardingViewModel()
    @State private var hasCompleted = false

    let onComplete: () -> Void

    var body: some View {
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
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.6)
        )
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
