import AppKit
import ApplicationServices
import SwiftUI

// MARK: - Models

struct LiveWindowInfo: Equatable {
    let surfaceID: String
    let pid: pid_t
    let bundleIdentifier: String
    let appName: String
    let appIcon: NSImage
    let windowTitle: String
    let windowID: CGWindowID
    let windowIndex: Int

    static func == (lhs: LiveWindowInfo, rhs: LiveWindowInfo) -> Bool {
        lhs.surfaceID == rhs.surfaceID
            && lhs.pid == rhs.pid
            && lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.appName == rhs.appName
            && lhs.windowTitle == rhs.windowTitle
            && lhs.windowID == rhs.windowID
            && lhs.windowIndex == rhs.windowIndex
    }
}

struct DeadWindowRow: Identifiable, Equatable {
    let id: String
    let usage: WindowUsageRecord
    let live: LiveWindowInfo
    let ageBucket: DeadWindowAgeBucket

    init(usage: WindowUsageRecord, live: LiveWindowInfo, ageBucket: DeadWindowAgeBucket) {
        self.id = usage.surfaceID
        self.usage = usage
        self.live = live
        self.ageBucket = ageBucket
    }
}

enum DeadWindowThreshold: Int, CaseIterable, Identifiable {
    case oneDay = 1
    case threeDays = 3
    case fiveDays = 5
    case oneWeek = 7
    case twoWeeks = 14
    case oneMonth = 30

    var id: Int { rawValue }

    var shortLabel: String {
        switch self {
        case .oneDay: return "1d"
        case .threeDays: return "3d"
        case .fiveDays: return "5d"
        case .oneWeek: return "1w"
        case .twoWeeks: return "2w"
        case .oneMonth: return "1mo"
        }
    }

    static let userDefaultsKey = "com.chakshujain.windowlens.deadWindows.thresholdDays"

    static func loadSaved() -> DeadWindowThreshold {
        let stored = UserDefaults.standard.integer(forKey: userDefaultsKey)
        return DeadWindowThreshold(rawValue: stored) ?? .fiveDays
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.userDefaultsKey)
    }
}

enum DeadWindowAgeBucket: String, CaseIterable, Identifiable {
    case oneToThreeDays = "1–3 days"
    case threeToSevenDays = "3–7 days"
    case oneToTwoWeeks = "1–2 weeks"
    case twoToFourWeeks = "2–4 weeks"
    case oneMonthPlus = "1+ month"

    var id: String { rawValue }

    var sortOrder: Int {
        switch self {
        case .oneToThreeDays: return 0
        case .threeToSevenDays: return 1
        case .oneToTwoWeeks: return 2
        case .twoToFourWeeks: return 3
        case .oneMonthPlus: return 4
        }
    }
}

struct DeadWindowsToast: Equatable {
    let message: String
    let showsUndo: Bool
}

struct MinimizeUndoBatch: Equatable {
    let rows: [DeadWindowRow]
}

// MARK: - Join logic

enum DeadWindowsJoinLogic {
    static func buildLiveLookup(from applications: [ApplicationModel]) -> [String: LiveWindowInfo] {
        var lookup: [String: LiveWindowInfo] = [:]

        for app in applications {
            for (index, window) in app.windows.enumerated() {
                guard !window.isWindowlessPlaceholder else { continue }

                let surfaceID = window.previewIdentity.stableKey
                guard !surfaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

                lookup[surfaceID] = LiveWindowInfo(
                    surfaceID: surfaceID,
                    pid: app.pid,
                    bundleIdentifier: app.bundleIdentifier,
                    appName: app.name,
                    appIcon: app.icon,
                    windowTitle: window.title,
                    windowID: window.windowID,
                    windowIndex: index
                )
            }
        }

        return lookup
    }

    static func joinedRows(
        staleRecords: [WindowUsageRecord],
        lookup: [String: LiveWindowInfo],
        now: Date = Date()
    ) -> [DeadWindowRow] {
        let stale = staleRecords

        let rows = stale.compactMap { record -> DeadWindowRow? in
            guard let live = lookup[record.surfaceID] else { return nil }
            let bucket = ageBucket(for: record.lastAccessedAt, now: now)
            return DeadWindowRow(usage: record, live: live, ageBucket: bucket)
        }

        return rows.sorted { lhs, rhs in
            if lhs.ageBucket.sortOrder != rhs.ageBucket.sortOrder {
                return lhs.ageBucket.sortOrder < rhs.ageBucket.sortOrder
            }
            return lhs.usage.lastAccessedAt < rhs.usage.lastAccessedAt
        }
    }

    static func groupedSections(from rows: [DeadWindowRow]) -> [(DeadWindowAgeBucket, [DeadWindowRow])] {
        var grouped: [DeadWindowAgeBucket: [DeadWindowRow]] = [:]
        for row in rows {
            grouped[row.ageBucket, default: []].append(row)
        }

        return DeadWindowAgeBucket.allCases.compactMap { bucket in
            guard let sectionRows = grouped[bucket], !sectionRows.isEmpty else { return nil }
            return (bucket, sectionRows)
        }
    }

    static func ageBucket(for lastAccessedAt: Date, now: Date) -> DeadWindowAgeBucket {
        let days = max(0, now.timeIntervalSince(lastAccessedAt) / 86_400)

        if days < 3 {
            return .oneToThreeDays
        }
        if days < 7 {
            return .threeToSevenDays
        }
        if days < 14 {
            return .oneToTwoWeeks
        }
        if days < 30 {
            return .twoToFourWeeks
        }
        return .oneMonthPlus
    }

    static func thresholdDate(for threshold: DeadWindowThreshold, now: Date = Date()) -> Date {
        Calendar.current.date(byAdding: .day, value: -threshold.rawValue, to: now) ?? now
    }
}

// MARK: - AX

private enum DeadWindowsAX {
    static func minimize(_ live: LiveWindowInfo) -> Bool {
        guard let axWindow = axWindow(for: live) else { return false }
        return AXUIElementSetAttributeValue(
            axWindow,
            kAXMinimizedAttribute as CFString,
            true as CFTypeRef
        ) == .success
    }

    static func unminimize(_ live: LiveWindowInfo) -> Bool {
        guard let axWindow = axWindow(for: live) else { return false }
        return AXUIElementSetAttributeValue(
            axWindow,
            kAXMinimizedAttribute as CFString,
            false as CFTypeRef
        ) == .success
    }

    static func close(_ live: LiveWindowInfo) -> Bool {
        guard let axWindow = axWindow(for: live) else { return false }
        return AXWindowHelper.closeWindow(axWindow, pid: live.pid, windowID: live.windowID)
    }

    private static func axWindow(for live: LiveWindowInfo) -> AXUIElement? {
        AXWindowHelper.getAXWindow(for: live.windowID, pid: live.pid)
    }
}

// MARK: - View model

@MainActor
final class DeadWindowsViewModel: ObservableObject {
    @Published private(set) var rows: [DeadWindowRow] = []
    @Published private(set) var sections: [(DeadWindowAgeBucket, [DeadWindowRow])] = []
    @Published var selectedIDs: Set<String> = []
    @Published var threshold: DeadWindowThreshold = DeadWindowThreshold.loadSaved() {
        didSet {
            threshold.save()
            refresh()
        }
    }
    @Published var toast: DeadWindowsToast?
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()

    private var pendingMinimizeUndo: MinimizeUndoBatch?
    private var toastDismissTask: Task<Void, Never>?

    var rowCount: Int { rows.count }

    var isAllSelected: Bool {
        !rows.isEmpty && selectedIDs.count == rows.count
    }

    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        let applications = WindowCache.shared.getApplicationsSync(forceRefresh: true)
        let lookup = DeadWindowsJoinLogic.buildLiveLookup(from: applications)
        let thresholdDate = DeadWindowsJoinLogic.thresholdDate(for: threshold)
        let staleRecords = WindowUsageStore.shared.windowsNotAccessedSince(thresholdDate)
        rows = DeadWindowsJoinLogic.joinedRows(staleRecords: staleRecords, lookup: lookup)
        sections = DeadWindowsJoinLogic.groupedSections(from: rows)
        selectedIDs = selectedIDs.intersection(Set(rows.map(\.id)))
    }

    func toggleSelectAll() {
        if isAllSelected {
            selectedIDs.removeAll()
        } else {
            selectedIDs = Set(rows.map(\.id))
        }
    }

    func minimize(rows targetRows: [DeadWindowRow]) {
        guard accessibilityGranted, !targetRows.isEmpty else { return }

        var succeeded: [DeadWindowRow] = []
        var failed = 0

        for row in targetRows {
            if DeadWindowsAX.minimize(row.live) {
                succeeded.append(row)
            } else {
                failed += 1
            }
            selectedIDs.remove(row.id)
        }

        removeRows(withIDs: Set(targetRows.map(\.id)))
        WindowCache.shared.invalidate()

        if !succeeded.isEmpty {
            pendingMinimizeUndo = MinimizeUndoBatch(rows: succeeded)
            presentToast(DeadWindowsToast(message: "Minimized — Undo", showsUndo: true))
        } else if failed > 0 {
            pendingMinimizeUndo = nil
            presentToast(DeadWindowsToast(message: "Couldn't minimize — removed from list", showsUndo: false))
        }
    }

    func close(rows targetRows: [DeadWindowRow]) {
        guard accessibilityGranted, !targetRows.isEmpty else { return }

        for row in targetRows {
            _ = DeadWindowsAX.close(row.live)
            selectedIDs.remove(row.id)
        }

        let count = targetRows.count
        removeRows(withIDs: Set(targetRows.map(\.id)))
        pendingMinimizeUndo = nil
        WindowCache.shared.invalidate()
        presentToast(
            DeadWindowsToast(
                message: count == 1 ? "1 window closed" : "\(count) windows closed",
                showsUndo: false
            )
        )
    }

    func minimizeSelected() {
        minimize(rows: rows.filter { selectedIDs.contains($0.id) })
    }

    func closeSelected() {
        close(rows: rows.filter { selectedIDs.contains($0.id) })
    }

    func performUndo() {
        guard let batch = pendingMinimizeUndo else { return }

        for row in batch.rows {
            _ = DeadWindowsAX.unminimize(row.live)
        }

        pendingMinimizeUndo = nil
        toast = nil
        refresh()
    }

    func dismissToast() {
        toast = nil
        toastDismissTask?.cancel()
        toastDismissTask = nil
    }

    private func removeRows(withIDs ids: Set<String>) {
        rows.removeAll { ids.contains($0.id) }
        sections = DeadWindowsJoinLogic.groupedSections(from: rows)
    }

    private func presentToast(_ newToast: DeadWindowsToast) {
        toast = newToast
        toastDismissTask?.cancel()
        toastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(newToast.showsUndo ? 8 : 3.5))
            guard !Task.isCancelled else { return }
            self?.toast = nil
            if !newToast.showsUndo {
                self?.pendingMinimizeUndo = nil
            }
        }
    }
}

// MARK: - View

struct DeadWindowsView: View {
    var isInline: Bool = false

    @StateObject private var viewModel = DeadWindowsViewModel()

    var body: some View {
        Group {
            if isInline {
                deadWindowsContent
            } else {
                NavigationStack {
                    deadWindowsContent
                        .navigationTitle("Unused Windows")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") {
                                    DeadWindowsWindowConfigurator.closeWindow()
                                }
                                .keyboardShortcut("w", modifiers: .command)
                            }

                            ToolbarItem(placement: .primaryAction) {
                                deadWindowsCountBadge
                            }

                            ToolbarItemGroup(placement: .automatic) {
                                deadWindowsBulkActions
                            }
                        }
                }
                .frame(minWidth: 680, minHeight: 520)
            }
        }
        .onAppear {
            viewModel.refresh()
        }
        .animation(.easeInOut(duration: 0.18), value: viewModel.toast)
    }

    private var deadWindowsContent: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if isInline {
                    inlineHeader
                }

                if !viewModel.accessibilityGranted {
                    accessibilityBanner
                }

                thresholdPills
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                if viewModel.rows.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(viewModel.sections, id: \.0.id) { bucket, sectionRows in
                            Section(bucket.rawValue) {
                                ForEach(sectionRows) { row in
                                    DeadWindowRowView(
                                        row: row,
                                        isSelected: viewModel.selectedIDs.contains(row.id),
                                        onToggleSelection: {
                                            toggleSelection(for: row.id)
                                        },
                                        onMinimize: {
                                            viewModel.minimize(rows: [row])
                                        },
                                        onClose: {
                                            viewModel.close(rows: [row])
                                        }
                                    )
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }

            if let toast = viewModel.toast {
                DeadWindowsToastView(
                    toast: toast,
                    onUndo: toast.showsUndo ? { viewModel.performUndo() } : nil,
                    onDismiss: { viewModel.dismissToast() }
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var inlineHeader: some View {
        HStack(spacing: 10) {
            Text("Unused Windows")
                .font(.system(size: 13, weight: .semibold))

            deadWindowsCountBadge

            Spacer(minLength: 0)

            deadWindowsBulkActions
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var deadWindowsCountBadge: some View {
        Text("\(viewModel.rowCount)")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.08))
            )
            .accessibilityLabel("\(viewModel.rowCount) unused windows")
    }

    @ViewBuilder
    private var deadWindowsBulkActions: some View {
        HStack(spacing: 8) {
            Button(viewModel.isAllSelected ? "Deselect All" : "Select All") {
                viewModel.toggleSelectAll()
            }
            .disabled(viewModel.rows.isEmpty)

            Button("Minimize") {
                viewModel.minimizeSelected()
            }
            .disabled(viewModel.selectedIDs.isEmpty || !viewModel.accessibilityGranted)

            Button("Close") {
                viewModel.closeSelected()
            }
            .disabled(viewModel.selectedIDs.isEmpty || !viewModel.accessibilityGranted)
        }
        .controlSize(.small)
    }

    private var accessibilityBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
            Text("Accessibility permission is required to minimize or close windows.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Open Settings") {
                NotificationCenter.default.post(name: .openPermissions, object: nil)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
    }

    private var thresholdPills: some View {
        HStack(spacing: 6) {
            Text("Unused for at least")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            ForEach(DeadWindowThreshold.allCases) { option in
                Button {
                    viewModel.threshold = option
                } label: {
                    Text(option.shortLabel)
                        .font(.system(size: 11, weight: viewModel.threshold == option ? .semibold : .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(
                                    viewModel.threshold == option
                                        ? Color.accentColor.opacity(0.22)
                                        : Color.primary.opacity(0.06)
                                )
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No unused open windows")
                .font(.system(size: 15, weight: .semibold))
            Text("Nothing open matches the \"\(viewModel.threshold.shortLabel)\" threshold.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func toggleSelection(for id: String) {
        if viewModel.selectedIDs.contains(id) {
            viewModel.selectedIDs.remove(id)
        } else {
            viewModel.selectedIDs.insert(id)
        }
    }
}

private struct DeadWindowRowView: View {
    let row: DeadWindowRow
    let isSelected: Bool
    let onToggleSelection: () -> Void
    let onMinimize: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { isSelected },
                set: { _ in onToggleSelection() }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()

            Image(nsImage: row.live.appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.live.windowTitle.isEmpty ? row.live.appName : row.live.windowTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isHovered {
                HStack(spacing: 6) {
                    Button(action: onMinimize) {
                        Image(systemName: "minus.rectangle")
                    }
                    .help("Minimize")

                    Button(action: onClose) {
                        Image(systemName: "xmark.circle")
                    }
                    .help("Close")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var subtitle: String {
        let relative = RelativeDateTimeFormatter().localizedString(
            for: row.usage.lastAccessedAt,
            relativeTo: Date()
        )
        return "\(row.live.appName) · last used \(relative)"
    }
}

private struct DeadWindowsToastView: View {
    let toast: DeadWindowsToast
    let onUndo: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.message)
                .font(.system(size: 12, weight: .medium))

            Spacer(minLength: 0)

            if let onUndo {
                Button("Undo", action: onUndo)
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .semibold))
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            FrostedPanelBackground(cornerRadius: 12, shadowOpacity: 0.12, shadowRadius: 10, shadowYOffset: 4)
        )
    }
}
