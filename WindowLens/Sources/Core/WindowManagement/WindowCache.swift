import Foundation
import AppKit
import Combine

/// High-performance window cache with short synchronized reads for safe background refresh.
final class WindowCache: @unchecked Sendable {
    static let shared = WindowCache()

    private var cache: [ApplicationModel] = []
    private var lastUpdate: Date?
    private let ttl: TimeInterval = 2.0  // 2 second cache - longer TTL since we refresh on activation
    private let lock = NSLock()
    private let enumerationLock = NSLock()

    // Track if a prefetch is in progress to avoid duplicate work
    private var prefetchInProgress = false

    private let enumerator = WindowEnumerator()
    private var workspaceObservers: [NSObjectProtocol] = []

    private init() {}

    /// Get cached applications WITHOUT blocking - returns stale data if cache is being refreshed
    /// This is the fast path for UI display
    func getCachedApplications() -> [ApplicationModel] {
        lock.lock()
        defer { lock.unlock() }
        return cache
    }

    /// Check if we have any cached data
    var hasCachedData: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cache.isEmpty
    }

    /// Get applications - uses cache if valid, otherwise enumerates synchronously
    /// WARNING: This can block if called while prefetch is running
    func getApplicationsSync(forceRefresh: Bool = false) -> [ApplicationModel] {
        lock.lock()
        if !forceRefresh,
           let lastUpdate = lastUpdate,
           Date().timeIntervalSince(lastUpdate) < ttl,
           !cache.isEmpty {
            let cachedApplications = cache
            lock.unlock()
            return cachedApplications
        }

        let existingOrder = cache.map { $0.pid }
        lock.unlock()

        var freshApplications = enumerateApplications(options: enumerationOptions())
        attachResourceUsage(to: &freshApplications)
        return updateCache(with: freshApplications, preservingOrder: existingOrder)
    }

    func getApplicationsForNativePreview() -> [ApplicationModel] {
        let existingOrder = getCachedApplications().map { $0.pid }
        var applications = enumerateApplications(
            options: enumerationOptions(includeAllSpacesOverride: true)
        )
        attachResourceUsage(to: &applications)
        applications = applications.map(WindowEnumerator.normalizeFinderApplicationIfNeeded)

        return mergeApplications(applications, preservingOrder: existingOrder)
    }

    func getApplicationsForWorkspaceSwitching(forceRefresh: Bool = false) -> [ApplicationModel] {
        let existingOrder = getCachedApplications().map { $0.pid }

        if !forceRefresh && !existingOrder.isEmpty {
            let cached = getCachedApplications()
            if !containsStaleFinderPlaceholder(in: cached) {
                return cached
            }
        }

        var applications = enumerateApplications(options: enumerationOptions())
        attachResourceUsage(to: &applications)

        return mergeApplications(applications, preservingOrder: existingOrder)
    }

    private func containsStaleFinderPlaceholder(in applications: [ApplicationModel]) -> Bool {
        guard let finder = applications.first(where: { $0.bundleIdentifier == WindowEnumerator.finderBundleIdentifier }) else {
            return false
        }

        let hasRealWindows = finder.windows.contains { !$0.isWindowlessPlaceholder }
        guard !hasRealWindows else { return false }

        return WindowEnumerator.finderHasMainWindow(pid: finder.pid)
    }

    private func enumerateApplications(options: WindowEnumerator.EnumerationOptions) -> [ApplicationModel] {
        enumerationLock.lock()
        defer { enumerationLock.unlock() }
        return enumerator.enumerateGroupedByApp(options: options)
    }

    private func updateCache(
        with freshApplications: [ApplicationModel],
        preservingOrder existingOrder: [pid_t]
    ) -> [ApplicationModel] {
        let mergedApplications = mergeApplications(freshApplications, preservingOrder: existingOrder)
        lock.lock()
        cache = mergedApplications
        lastUpdate = Date()
        lock.unlock()
        return mergedApplications
    }

    func applicationMatchingForNativePreview(
        pid: pid_t?,
        bundleIdentifier: String?
    ) -> ApplicationModel? {
        guard let app = applicationMatching(
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            in: getApplicationsForNativePreview()
        ) else {
            return nil
        }

        return WindowEnumerator.normalizeFinderApplicationIfNeeded(app)
    }

    func applicationMatching(
        pid: pid_t?,
        bundleIdentifier: String?,
        forceRefreshIfMissing: Bool = true
    ) -> ApplicationModel? {
        if let match = applicationMatching(pid: pid, bundleIdentifier: bundleIdentifier, in: getCachedApplications()) {
            return match
        }

        guard forceRefreshIfMissing else { return nil }
        return applicationMatching(
            pid: pid,
            bundleIdentifier: bundleIdentifier,
            in: getApplicationsSync(forceRefresh: true)
        )
    }

    private func applicationMatching(
        pid: pid_t?,
        bundleIdentifier: String?,
        in applications: [ApplicationModel]
    ) -> ApplicationModel? {
        if let pid, let app = applications.first(where: { $0.pid == pid }) {
            return app
        }

        if let bundleIdentifier, let app = applications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return app
        }

        return nil
    }

    /// Async wrapper for compatibility
    func getApplications(forceRefresh: Bool = false) async -> [ApplicationModel] {
        return getApplicationsSync(forceRefresh: forceRefresh)
    }

    /// Pre-fetch window data - runs enumeration and updates cache
    /// Call this early so data is ready when needed
    /// IMPORTANT: This preserves MRU order from existing cache
    func prefetch() {
        // Don't start another prefetch if one is already running
        lock.lock()
        if prefetchInProgress {
            lock.unlock()
            return
        }
        prefetchInProgress = true

        // Capture existing order BEFORE releasing lock
        let existingOrder = cache.map { $0.pid }
        lock.unlock()

        // Run enumeration (this is the slow part - don't hold lock during this!)
        var freshApplications = enumerateApplications(options: enumerationOptions())
        attachResourceUsage(to: &freshApplications)

        // Merge: preserve MRU order from existing cache, but use fresh window data
        let mergedApplications: [ApplicationModel]
        if existingOrder.isEmpty {
            // No existing order - use fresh data as-is
            mergedApplications = freshApplications
        } else {
            // Build a lookup of fresh apps by PID
            var freshByPid: [pid_t: ApplicationModel] = [:]
            for app in freshApplications {
                freshByPid[app.pid] = app
            }

            // Start with apps in existing order (that still exist)
            var result: [ApplicationModel] = []
            var usedPids: Set<pid_t> = []

            for pid in existingOrder {
                if let freshApp = freshByPid[pid] {
                    result.append(freshApp)
                    usedPids.insert(pid)
                }
            }

            // Add any new apps that weren't in old cache (at the end)
            for app in freshApplications {
                if !usedPids.contains(app.pid) {
                    result.append(app)
                }
            }

            mergedApplications = result
        }

        // Update cache atomically
        lock.lock()
        cache = mergedApplications
        lastUpdate = Date()
        prefetchInProgress = false
        lock.unlock()

        print("[WindowCache] Prefetch complete, \(mergedApplications.count) apps, preserved MRU order")
    }

    /// Prefetch on background thread - non-blocking
    func prefetchAsync(onComplete: (@MainActor () -> Void)? = nil) {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.prefetch()
            guard let onComplete else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    onComplete()
                }
            }
        }
    }

    func invalidate() {
        lock.lock()
        lastUpdate = nil
        lock.unlock()
    }

    func clearPreviewImages(reason: String) {
        lock.lock()
        for appIndex in cache.indices {
            for windowIndex in cache[appIndex].windows.indices {
                cache[appIndex].windows[windowIndex].previewImage = nil
            }
        }
        lock.unlock()

        print("[WindowCache] Preview image references cleared: \(reason)")
    }

    /// Move an app to the front of the cache. This is much faster than re-enumerating all windows.
    func moveAppToFront(pid: pid_t, fromOurSwitch: Bool = false) {
        lock.lock()
        defer { lock.unlock() }

        guard let index = cache.firstIndex(where: { $0.pid == pid }) else {
            // App not in cache - invalidate so next fetch gets fresh data
            print("[WindowCache] moveAppToFront: app PID \(pid) not in cache, invalidating")
            lastUpdate = nil
            return
        }

        let appName = cache[index].name

        // Move the activated app to the front
        let app = cache.remove(at: index)
        cache.insert(app, at: 0)

        // Mark the app as active, others as not active
        for i in cache.indices {
            cache[i] = ApplicationModel(
                pid: cache[i].pid,
                bundleIdentifier: cache[i].bundleIdentifier,
                name: cache[i].name,
                icon: cache[i].icon,
                windows: cache[i].windows,
                isActive: i == 0,
                memoryBytes: cache[i].memoryBytes
            )
        }

        // Log the new order (top 5 apps)
        let topApps = cache.prefix(5).map { $0.name }.joined(separator: " > ")
        let source = fromOurSwitch ? "WindowLens" : "system"
        print("[WindowCache] moveAppToFront: \(appName) moved from index \(index) to front via \(source). Order: \(topApps)")
    }

    @discardableResult
    func reconcileActivatedApplication(_ runningApplication: NSRunningApplication) -> [ApplicationModel] {
        let pid = runningApplication.processIdentifier
        guard pid >= 0, runningApplication.activationPolicy == .regular else {
            return getCachedApplications()
        }

        moveAppToFront(pid: pid, fromOurSwitch: false)
        let snapshot = getCachedApplications()

        guard snapshot.contains(where: { $0.pid == pid }) else {
            _ = getApplicationsSync(forceRefresh: true)
            moveAppToFront(pid: pid, fromOurSwitch: false)
            return getCachedApplications()
        }

        return snapshot
    }

    @discardableResult
    func reconcileFrontmostApplication() -> [ApplicationModel] {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else {
            return getCachedApplications()
        }

        return reconcileActivatedApplication(frontmostApplication)
    }

    /// Attach resource usage data to applications (lightweight, ~1-3ms)
    private func attachResourceUsage(to apps: inout [ApplicationModel]) {
        let pids = apps.map { $0.pid }
        let snapshot = ProcessResourceMonitor.shared.snapshot(pids: pids)
        for i in apps.indices {
            if let usage = snapshot[apps[i].pid] {
                apps[i].memoryBytes = usage.memoryBytes
            }
        }
    }

    private func enumerationOptions(includeAllSpacesOverride: Bool? = nil) -> WindowEnumerator.EnumerationOptions {
        let preferences = UserPreferences.load()
        return WindowEnumerator.EnumerationOptions(
            includeMinimized: preferences.showMinimizedWindows,
            includeAllSpaces: includeAllSpacesOverride ?? preferences.showAllSpaces
        )
    }

    private func mergeApplications(
        _ freshApplications: [ApplicationModel],
        preservingOrder existingOrder: [pid_t]
    ) -> [ApplicationModel] {
        guard !existingOrder.isEmpty else {
            return freshApplications
        }

        var freshByPid: [pid_t: ApplicationModel] = [:]
        for app in freshApplications {
            freshByPid[app.pid] = app
        }

        var result: [ApplicationModel] = []
        var usedPids: Set<pid_t> = []

        for pid in existingOrder {
            if let freshApp = freshByPid[pid] {
                result.append(freshApp)
                usedPids.insert(pid)
            }
        }

        for app in freshApplications where !usedPids.contains(app.pid) {
            result.append(app)
        }

        return result
    }

    func startMonitoring() {
        guard workspaceObservers.isEmpty else {
            print("[WindowCache] Workspace monitoring already started")
            return
        }

        let workspace = NSWorkspace.shared
        let notificationCenter = workspace.notificationCenter

        // Track app activations to maintain correct MRU order
        let activateObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }

            let pid = app.processIdentifier

            let applications = self.reconcileActivatedApplication(app)
            print("[WindowCache] App activation reconciled: \(app.localizedName ?? "unknown")")
            NotificationCenter.default.post(
                name: .workspaceActiveApplicationDidReconcile,
                object: self,
                userInfo: [
                    "pid": pid,
                    "applications": applications
                ]
            )
        }
        workspaceObservers.append(activateObserver)

        // App launch/terminate require immediate cache refresh (not just invalidation)
        let refreshNotifications: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]

        for name in refreshNotifications {
            let observer = notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self = self else { return }
                let appName = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.localizedName ?? "unknown"
                print("[WindowCache] App \(name == NSWorkspace.didLaunchApplicationNotification ? "launched" : "terminated"): \(appName), refreshing cache")
                self.invalidate()
                self.prefetchAsync()
            }
            workspaceObservers.append(observer)
        }

        // Space change just needs invalidation (will refresh on next access)
        let spaceObserver = notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.invalidate()
            let applications = self.reconcileFrontmostApplication()
            let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
            NotificationCenter.default.post(
                name: .workspaceActiveApplicationDidReconcile,
                object: self,
                userInfo: [
                    "pid": pid,
                    "applications": applications
                ]
            )
            self.prefetchAsync()
        }
        workspaceObservers.append(spaceObserver)

        print("[WindowCache] Started monitoring workspace notifications")
    }

    func stopMonitoring() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        print("[WindowCache] Stopped monitoring workspace notifications")
    }
}

extension Notification.Name {
    static let workspaceActiveApplicationDidReconcile = Notification.Name("workspaceActiveApplicationDidReconcile")
}
