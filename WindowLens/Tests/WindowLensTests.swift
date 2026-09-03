import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import WindowLens

final class WindowLensTests: XCTestCase {

    // MARK: - ModifierKeyTracker Tests

    func testModifierKeyTrackerCommand() {
        let tracker = ModifierKeyTracker()
        tracker.update(flags: .maskCommand)

        XCTAssertTrue(tracker.isCommandPressed)
        XCTAssertFalse(tracker.isShiftPressed)
        XCTAssertFalse(tracker.isOptionPressed)
        XCTAssertFalse(tracker.isControlPressed)
    }

    func testModifierKeyTrackerMultiple() {
        let tracker = ModifierKeyTracker()
        tracker.update(flags: [.maskCommand, .maskShift])

        XCTAssertTrue(tracker.isCommandPressed)
        XCTAssertTrue(tracker.isShiftPressed)
        XCTAssertFalse(tracker.isOptionPressed)
    }

    func testModifierKeyTrackerMatches() {
        let tracker = ModifierKeyTracker()
        tracker.update(flags: [.maskCommand, .maskShift])

        XCTAssertTrue(tracker.matches([.command, .shift]))
        XCTAssertFalse(tracker.matches([.command]))
        XCTAssertFalse(tracker.matches([.command, .option]))
    }

    func testModifierKeyTrackerContains() {
        let tracker = ModifierKeyTracker()
        tracker.update(flags: [.maskCommand, .maskShift, .maskAlternate])

        XCTAssertTrue(tracker.contains([.command]))
        XCTAssertTrue(tracker.contains([.command, .shift]))
        XCTAssertFalse(tracker.contains([.control]))
    }

    // MARK: - FuzzyMatcher Tests

    func testFuzzyMatcherExactMatch() {
        let apps = [
            makeApp(name: "Safari"),
            makeApp(name: "Chrome"),
            makeApp(name: "Firefox")
        ]

        let filtered = FuzzyMatcher.filter(apps, query: "Safari")

        XCTAssertEqual(filtered.first?.name, "Safari")
    }

    func testFuzzyMatcherPartialMatch() {
        let apps = [
            makeApp(name: "Safari"),
            makeApp(name: "Slack"),
            makeApp(name: "System Preferences")
        ]

        let filtered = FuzzyMatcher.filter(apps, query: "sa")

        XCTAssertTrue(filtered.contains { $0.name == "Safari" })
        XCTAssertTrue(filtered.contains { $0.name == "Slack" })
    }

    func testFuzzyMatcherFuzzyMatch() {
        let apps = [
            makeApp(name: "Visual Studio Code"),
            makeApp(name: "Finder")
        ]

        let filtered = FuzzyMatcher.filter(apps, query: "vsc")

        XCTAssertEqual(filtered.first?.name, "Visual Studio Code")
    }

    func testFuzzyMatcherEmptyQuery() {
        let apps = [makeApp(name: "Safari"), makeApp(name: "Chrome")]

        let filtered = FuzzyMatcher.filter(apps, query: "")

        XCTAssertEqual(filtered.count, apps.count)
    }

    func testFuzzyMatcherNoMatch() {
        let apps = [makeApp(name: "Safari")]

        let filtered = FuzzyMatcher.filter(apps, query: "xyz123")

        XCTAssertTrue(filtered.isEmpty)
    }

    func testFuzzyMatcherCaseInsensitive() {
        let apps = [makeApp(name: "Safari")]

        let filtered = FuzzyMatcher.filter(apps, query: "SAFARI")

        XCTAssertEqual(filtered.count, 1)
    }

    func testFuzzyMatcherMatchesSingleWindowTitle() {
        var messages = makeApp(pid: 42, name: "Messages")
        messages.windows = [WindowModel(windowID: 99, title: "Goldfish")]

        let results = FuzzyMatcher.search([messages], query: "Goldfish")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.matchedText, "Goldfish")
        XCTAssertEqual(results.first?.targetWindowIndex, 0)
    }

    // MARK: - WindowModel Tests

    func testWindowModelEquality() {
        let window1 = WindowModel(windowID: 123, title: "Test Window")
        let window2 = WindowModel(windowID: 123, title: "Different Title")
        let window3 = WindowModel(windowID: 456, title: "Test Window")

        XCTAssertEqual(window1, window2)  // Same windowID
        XCTAssertNotEqual(window1, window3)  // Different windowID
    }

    // MARK: - ApplicationModel Tests

    func testApplicationModelEquality() {
        let app1 = makeApp(pid: 100, name: "App1")
        let app2 = makeApp(pid: 100, name: "App2")
        let app3 = makeApp(pid: 200, name: "App1")

        XCTAssertEqual(app1, app2)  // Same PID
        XCTAssertNotEqual(app1, app3)  // Different PID
    }

    func testApplicationModelWindowCount() {
        let app = ApplicationModel(
            pid: 1,
            bundleIdentifier: "com.test",
            name: "Test",
            icon: NSImage(),
            windows: [
                WindowModel(windowID: 1, title: "W1"),
                WindowModel(windowID: 2, title: "W2")
            ]
        )

        XCTAssertEqual(app.windowCount, 2)
        XCTAssertTrue(app.hasMultipleWindows)
    }

    // MARK: - UserPreferences Tests

    func testUserPreferencesDefaults() {
        let prefs = UserPreferences()

        XCTAssertEqual(prefs.activationModifier, .option)
        XCTAssertFalse(prefs.useSystemShortcut)
        XCTAssertFalse(prefs.showAllSpaces)
        XCTAssertTrue(prefs.showMinimizedWindows)
        XCTAssertEqual(prefs.shortcuts.windowHistoryBack, ShortcutAction.windowHistoryBack.defaultBinding)
        XCTAssertEqual(prefs.shortcuts.windowSlotModifier, .control)
    }

    // MARK: - KeyboardShortcutBinding Tests

    func testKeyboardShortcutBindingMatchesDefaultHistoryBack() {
        let binding = ShortcutAction.windowHistoryBack.defaultBinding
        var flags = CGEventFlags()
        flags.insert(.maskCommand)
        flags.insert(.maskShift)

        XCTAssertTrue(binding.matches(keyCode: UInt16(kVK_ANSI_Z), flags: flags))
        XCTAssertFalse(binding.matches(keyCode: UInt16(kVK_ANSI_Z), flags: [.maskCommand]))
    }

    func testKeyboardShortcutBindingDisplayString() {
        let binding = ShortcutAction.windowHistoryBack.defaultBinding
        XCTAssertEqual(binding.displayString, "⌘ ⇧ Z")
    }

    func testWorkspaceCommandStripCycleKeySymbolsOmitOpenModifier() {
        let workspaceOpen = ShortcutAction.workspaceOpen.defaultBinding
        XCTAssertEqual(
            WorkspaceCommandStripSymbols.cycleKeySymbols(from: workspaceOpen),
            ["tab"]
        )
    }

    func testWorkspaceCommandStripKeySymbolsIncludeModifiers() {
        let binding = KeyboardShortcutBinding(
            keyCode: UInt16(kVK_ANSI_E),
            modifiers: [.command, .shift]
        )
        XCTAssertEqual(
            WorkspaceCommandStripSymbols.keySymbols(for: binding),
            ["cmd", "shift", "E"]
        )
    }

    func testWorkspaceCommandStripKeySymbolMapsNavigationKeys() {
        XCTAssertEqual(WorkspaceCommandStripSymbols.keySymbol(for: UInt16(kVK_UpArrow)), "up")
        XCTAssertEqual(WorkspaceCommandStripSymbols.keySymbol(for: UInt16(kVK_DownArrow)), "down")
        XCTAssertEqual(WorkspaceCommandStripSymbols.keySymbol(for: UInt16(kVK_Escape)), "esc")
    }

    func testSearchBarPlaceholderCurrentAppScope() {
        XCTAssertEqual(
            SearchBarView.placeholder(scope: .currentApp, appName: "Safari"),
            "Search Safari windows…"
        )
    }

    func testSearchBarPlaceholderAllWindowsScope() {
        XCTAssertEqual(
            SearchBarView.placeholder(scope: .allWindows, appName: "Safari"),
            "Search all windows…"
        )
    }

    func testSearchBarPlaceholderFallsBackWhenAppNameMissing() {
        XCTAssertEqual(
            SearchBarView.placeholder(scope: .currentApp, appName: nil),
            "Search this app windows…"
        )
    }

    // MARK: - WindowUsageStore Tests

    @MainActor
    func testWindowUsageStoreUpsertIncrementsAccessCount() {
        let store = WindowUsageStore(forTestingWithMaxEntries: 100)
        let identity = makeUsagePreviewIdentity(windowID: 101, title: "Inbox")

        store.recordAccess(identity: identity, appName: "Mail", windowTitle: "Inbox")
        store.recordAccess(identity: identity, appName: "Mail", windowTitle: "Inbox")

        let stale = store.windowsNotAccessedSince(.distantFuture)
        XCTAssertEqual(stale.count, 1)
        XCTAssertEqual(stale[0].accessCount, 2)
        XCTAssertEqual(stale[0].lastAppName, "Mail")
        XCTAssertEqual(stale[0].lastWindowTitle, "Inbox")
        XCTAssertEqual(stale[0].surfaceID, identity.stableKey)
    }

    @MainActor
    func testWindowUsageStorePruneRemovesOldestBatch() {
        let store = WindowUsageStore(forTestingWithMaxEntries: 2, pruneBatchSize: 1)

        for index in 0..<3 {
            let identity = makeUsagePreviewIdentity(windowID: CGWindowID(200 + index), title: "Window \(index)")
            store.recordAccess(identity: identity, appName: "App", windowTitle: "Window \(index)")
            Thread.sleep(forTimeInterval: 0.005)
        }

        XCTAssertEqual(store.recordCountForTesting, 2)
        let remainingTitles = Set(
            store.windowsNotAccessedSince(.distantFuture).map(\.lastWindowTitle)
        )
        XCTAssertFalse(remainingTitles.contains("Window 0"))
        XCTAssertTrue(remainingTitles.contains("Window 1"))
        XCTAssertTrue(remainingTitles.contains("Window 2"))
    }

    @MainActor
    func testWindowUsageStoreWindowsNotAccessedSinceSortsOldestFirst() {
        let store = WindowUsageStore(forTestingWithMaxEntries: 100)
        let oldIdentity = makeUsagePreviewIdentity(windowID: 301, title: "Old")
        let newIdentity = makeUsagePreviewIdentity(windowID: 302, title: "New")

        store.recordAccess(identity: oldIdentity, appName: "App", windowTitle: "Old")
        Thread.sleep(forTimeInterval: 0.01)
        store.recordAccess(identity: newIdentity, appName: "App", windowTitle: "New")

        let cutoff = Date()
        let stale = store.windowsNotAccessedSince(cutoff)
        XCTAssertEqual(stale.count, 2)
        XCTAssertEqual(stale[0].lastWindowTitle, "Old")
        XCTAssertEqual(stale[1].lastWindowTitle, "New")
    }

    func testWindowUsageRecordPersistenceRoundTrip() throws {
        let now = Date()
        let records: [String: WindowUsageRecord] = [
            "pid:1:wid:2": WindowUsageRecord(
                surfaceID: "pid:1:wid:2",
                lastAccessedAt: now,
                accessCount: 3,
                lastAppName: "Safari",
                lastWindowTitle: "GitHub",
                firstSeenAt: now.addingTimeInterval(-3600)
            )
        ]

        let data = try JSONEncoder().encode(records)
        let decoded = try JSONDecoder().decode([String: WindowUsageRecord].self, from: data)
        XCTAssertEqual(decoded, records)
    }

    @MainActor
    func testWindowUsageStoreDecodeFailureStartsFresh() {
        let suiteName = "WindowUsageStoreTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        let key = "test.usage.\(UUID().uuidString)"
        userDefaults.set(Data([0xFF, 0x00, 0x01]), forKey: key)

        let store = WindowUsageStore(
            forTestingWithMaxEntries: 100,
            persistenceKey: key,
            userDefaults: userDefaults,
            loadPersistedData: true
        )

        XCTAssertEqual(store.recordCountForTesting, 0)
        XCTAssertNil(userDefaults.data(forKey: key))
    }

    @MainActor
    func testWindowUsageStorePersistsAcrossLoad() {
        let suiteName = "WindowUsageStoreTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        let key = "test.usage.\(UUID().uuidString)"
        let identity = makeUsagePreviewIdentity(windowID: 401, title: "Persist")

        let writer = WindowUsageStore(
            forTestingWithMaxEntries: 100,
            persistenceKey: key,
            userDefaults: userDefaults,
            loadPersistedData: false
        )
        writer.recordAccess(identity: identity, appName: "Notes", windowTitle: "Persist")
        writer.persistImmediatelyForTesting()

        let reader = WindowUsageStore(
            forTestingWithMaxEntries: 100,
            persistenceKey: key,
            userDefaults: userDefaults,
            loadPersistedData: true
        )

        XCTAssertEqual(reader.recordCountForTesting, 1)
        let records = reader.windowsNotAccessedSince(.distantFuture)
        XCTAssertEqual(records.first?.lastAppName, "Notes")
    }

    @MainActor
    func testWindowUsageStoreSkipsWindowLensAndPlaceholderIdentities() {
        let store = WindowUsageStore(forTestingWithMaxEntries: 100)

        let windowLensIdentity = PreviewIdentity(
            ownerPID: 1,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            cgWindowID: 1,
            title: "WindowLens",
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        store.recordAccess(identity: windowLensIdentity, appName: "WindowLens", windowTitle: "WindowLens")

        let placeholderIdentity = PreviewIdentity(
            ownerPID: 2,
            bundleIdentifier: "com.test.app",
            cgWindowID: 0,
            title: "",
            bounds: .zero,
            hasReliableCGWindowID: false
        )
        store.recordAccess(identity: placeholderIdentity, appName: "App", windowTitle: "")

        XCTAssertEqual(store.recordCountForTesting, 0)
    }

    @MainActor
    func testWindowUsageStoreClearAllRemovesPersistence() {
        let suiteName = "WindowUsageStoreTests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        let key = "test.usage.\(UUID().uuidString)"
        let store = WindowUsageStore(
            forTestingWithMaxEntries: 100,
            persistenceKey: key,
            userDefaults: userDefaults,
            loadPersistedData: false
        )
        let identity = makeUsagePreviewIdentity(windowID: 501, title: "Clear")
        store.recordAccess(identity: identity, appName: "App", windowTitle: "Clear")
        store.persistImmediatelyForTesting()
        XCTAssertNotNil(userDefaults.data(forKey: key))

        store.clearAll()
        XCTAssertEqual(store.recordCountForTesting, 0)
        XCTAssertNil(userDefaults.data(forKey: key))
    }

    // MARK: - Dead Windows join logic

    func testDeadWindowsBuildLiveLookupSkipsPlaceholders() {
        let app = makeApp(pid: 100, name: "Safari")
        let realWindow = WindowModel(
            windowID: 200,
            title: "GitHub",
            ownerPID: app.pid,
            bundleIdentifier: app.bundleIdentifier
        )
        let placeholder = WindowModel(
            windowID: 0,
            title: "No Windows",
            bounds: .zero,
            isMinimized: false,
            isOnScreen: false,
            ownerPID: app.pid,
            bundleIdentifier: app.bundleIdentifier,
            hasReliableWindowID: false,
            subtitle: "No Windows"
        )
        var appWithWindows = app
        appWithWindows.windows = [realWindow, placeholder]

        let lookup = DeadWindowsJoinLogic.buildLiveLookup(from: [appWithWindows])

        XCTAssertEqual(lookup.count, 1)
        XCTAssertEqual(lookup.values.first?.windowTitle, "GitHub")
        XCTAssertEqual(lookup.keys.first, realWindow.previewIdentity.stableKey)
    }

    func testDeadWindowsJoinedRowsExcludesGhosts() {
        let app = makeApp(pid: 200, name: "Notes")
        let window = WindowModel(
            windowID: 300,
            title: "Draft",
            ownerPID: app.pid,
            bundleIdentifier: app.bundleIdentifier
        )
        var notesApp = app
        notesApp.windows = [window]

        let lookup = DeadWindowsJoinLogic.buildLiveLookup(from: [notesApp])
        let now = Date()
        let stale: [WindowUsageRecord] = [
            WindowUsageRecord(
                surfaceID: window.previewIdentity.stableKey,
                lastAccessedAt: now.addingTimeInterval(-86_400 * 10),
                accessCount: 2,
                lastAppName: "Notes",
                lastWindowTitle: "Draft",
                firstSeenAt: now.addingTimeInterval(-86_400 * 30)
            ),
            WindowUsageRecord(
                surfaceID: "ghost-closed-window",
                lastAccessedAt: now.addingTimeInterval(-86_400 * 10),
                accessCount: 1,
                lastAppName: "Closed",
                lastWindowTitle: "Gone",
                firstSeenAt: now.addingTimeInterval(-86_400 * 30)
            )
        ]

        let rows = DeadWindowsJoinLogic.joinedRows(staleRecords: stale, lookup: lookup, now: now)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].live.windowTitle, "Draft")
    }

    func testDeadWindowsGroupedSectionsOrdersBuckets() {
        let app = makeApp(pid: 300, name: "Mail")
        let oldWindow = WindowModel(
            windowID: 400,
            title: "Old",
            ownerPID: app.pid,
            bundleIdentifier: app.bundleIdentifier
        )
        let olderWindow = WindowModel(
            windowID: 401,
            title: "Older",
            ownerPID: app.pid,
            bundleIdentifier: app.bundleIdentifier
        )
        var mailApp = app
        mailApp.windows = [oldWindow, olderWindow]

        let lookup = DeadWindowsJoinLogic.buildLiveLookup(from: [mailApp])
        let now = Date()
        let stale: [WindowUsageRecord] = [
            WindowUsageRecord(
                surfaceID: oldWindow.previewIdentity.stableKey,
                lastAccessedAt: now.addingTimeInterval(-86_400 * 10),
                accessCount: 1,
                lastAppName: "Mail",
                lastWindowTitle: "Old",
                firstSeenAt: now.addingTimeInterval(-86_400 * 20)
            ),
            WindowUsageRecord(
                surfaceID: olderWindow.previewIdentity.stableKey,
                lastAccessedAt: now.addingTimeInterval(-86_400 * 40),
                accessCount: 1,
                lastAppName: "Mail",
                lastWindowTitle: "Older",
                firstSeenAt: now.addingTimeInterval(-86_400 * 50)
            )
        ]

        let rows = DeadWindowsJoinLogic.joinedRows(staleRecords: stale, lookup: lookup, now: now)
        let sections = DeadWindowsJoinLogic.groupedSections(from: rows)

        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].0, .oneToTwoWeeks)
        XCTAssertEqual(sections[1].0, .oneMonthPlus)
    }

    func testDeadWindowsAgeBucketAssignment() {
        let now = Date()
        XCTAssertEqual(
            DeadWindowsJoinLogic.ageBucket(for: now.addingTimeInterval(-86_400 * 2), now: now),
            .oneToThreeDays
        )
        XCTAssertEqual(
            DeadWindowsJoinLogic.ageBucket(for: now.addingTimeInterval(-86_400 * 6.9), now: now),
            .threeToSevenDays
        )
        XCTAssertEqual(
            DeadWindowsJoinLogic.ageBucket(for: now.addingTimeInterval(-86_400 * 30), now: now),
            .oneMonthPlus
        )
    }

    func testDeadWindowThresholdDefaultIsFiveDays() {
        let key = DeadWindowThreshold.userDefaultsKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(DeadWindowThreshold.loadSaved(), .fiveDays)

        DeadWindowThreshold.threeDays.save()
        XCTAssertEqual(DeadWindowThreshold.loadSaved(), .threeDays)
    }

    func testShortcutPreferencesCodableRoundTrip() throws {
        var prefs = UserPreferences()
        prefs.shortcuts.windowHistoryBack = KeyboardShortcutBinding(
            keyCode: UInt16(kVK_ANSI_X),
            modifiers: [.command, .option]
        )

        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(UserPreferences.self, from: data)

        XCTAssertEqual(decoded.shortcuts.windowHistoryBack, prefs.shortcuts.windowHistoryBack)
    }

    func testShortcutBindingValidatorDetectsDuplicate() {
        var preferences = ShortcutPreferences()
        let duplicate = preferences.windowHistoryBack

        let error = ShortcutBindingValidator.validate(
            duplicate,
            for: .windowHistoryForward,
            in: preferences
        )

        XCTAssertNotNil(error)
        XCTAssertEqual(error, "That shortcut is already assigned.")
    }

    func testShortcutBindingValidatorDetectsReservedShortcut() {
        let reserved = KeyboardShortcutBinding(
            keyCode: UInt16(kVK_ANSI_Q),
            modifiers: [.command]
        )

        let error = ShortcutBindingValidator.validate(
            reserved,
            for: .windowHistoryBack,
            in: ShortcutPreferences()
        )

        XCTAssertNotNil(error)
        XCTAssertEqual(error, "That shortcut is reserved by macOS.")
    }

    func testWindowSlotDigitMatchingUsesConfiguredModifier() {
        var preferences = ShortcutPreferences()
        preferences.windowSlotModifier = .option

        var flags = CGEventFlags()
        flags.insert(.maskAlternate)

        XCTAssertEqual(preferences.matchesWindowSlotDigit(keyCode: UInt16(kVK_ANSI_3), flags: flags), 3)

        flags = [.maskControl]
        XCTAssertNil(preferences.matchesWindowSlotDigit(keyCode: UInt16(kVK_ANSI_3), flags: flags))
    }

    func testMergedWindowsPreservingPreviewsKeepsExistingImage() {
        let pid: pid_t = 10_001
        let windowID = CGWindowID(42)
        let image = NSImage(size: NSSize(width: 12, height: 12))

        let existing = WindowModel(
            windowID: windowID,
            title: "Welcome",
            ownerPID: pid,
            previewImage: image
        )
        let fresh = WindowModel(
            windowID: windowID,
            title: "Welcome",
            ownerPID: pid,
            previewImage: nil
        )

        let merged = WindowModel.mergedPreservingPreviews(fresh: [fresh], existing: [existing])

        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].previewImage === image)
    }

    func testMergedWindowsPreservingPreviewsMatchesByTitleWhenWindowIDChanges() {
        let pid: pid_t = 10_003
        let image = NSImage(size: NSSize(width: 12, height: 12))
        let existing = WindowModel(
            windowID: PreviewIdentity.pseudoWindowID(ownerPID: pid, axIndex: 0, title: "Welcome", bounds: .zero),
            title: "Welcome",
            ownerPID: pid,
            axIndex: 0,
            hasReliableWindowID: false,
            previewImage: image
        )
        let fresh = WindowModel(
            windowID: 9_001,
            title: "Welcome",
            ownerPID: pid,
            axIndex: 0,
            previewImage: nil
        )

        let merged = WindowModel.mergedPreservingPreviews(fresh: [fresh], existing: [existing])

        XCTAssertTrue(merged[0].previewImage === image)
        XCTAssertEqual(merged[0].carouselItemID, existing.carouselItemID)
    }

    // MARK: - Finder Window Enumeration

    func testFinderRefinementDropsGenericShellWhenBrowserWindowExists() {
        let windows = [
            makeFinderWindowInfo(title: "Desktop — Local", windowID: 100, axIndex: 0),
            makeFinderWindowInfo(title: "Finder", windowID: 200, axIndex: 1)
        ]

        let refined = refineFinderWindows(
            windows,
            visibleCGWindowIDs: [100, 200],
            cgWindowNamesByID: [100: "Desktop — Local", 200: "Finder"]
        )

        XCTAssertEqual(refined.count, 1)
        XCTAssertEqual(refined[0].windowName, "Desktop — Local")
    }

    func testFinderRefinementReplacesLoneRestoreShellWithNoWindowsPlaceholder() {
        let windows = [makeFinderWindowInfo(title: "Finder", windowID: 100)]

        let refined = refineFinderWindows(windows, visibleCGWindowIDs: [])

        XCTAssertEqual(refined.count, 1)
        XCTAssertEqual(refined[0].windowName, "No Windows")
        XCTAssertFalse(refined[0].hasReliableWindowID)
        XCTAssertEqual(refined[0].bounds, .zero)
        XCTAssertFalse(refined[0].isOnScreen)
    }

    func testFinderRefinementReplacesSingleOffScreenBrowserWithNoWindowsPlaceholder() {
        let windows = [
            makeFinderWindowInfo(
                title: "Desktop — Local",
                windowID: 100,
                bounds: CGRect(x: -12_000, y: 200, width: 900, height: 700),
                isOnScreen: true
            )
        ]

        let refined = refineFinderWindows(windows, visibleCGWindowIDs: [100])

        XCTAssertEqual(refined.count, 1)
        XCTAssertEqual(refined[0].windowName, "No Windows")
    }

    func testFinderRefinementReplacesSingleHiddenBrowserWithNoWindowsPlaceholder() {
        let windows = [
            makeFinderWindowInfo(title: "Desktop — Local", windowID: 100, isHidden: true)
        ]

        let refined = refineFinderWindows(windows, visibleCGWindowIDs: [100])

        XCTAssertEqual(refined.count, 1)
        XCTAssertEqual(refined[0].windowName, "No Windows")
    }

    func testFinderRefinementKeepsVisibleSingleBrowserWindow() {
        let windows = [makeFinderWindowInfo(title: "Desktop — Local", windowID: 100)]

        let refined = refineFinderWindows(
            windows,
            visibleCGWindowIDs: [100],
            cgWindowNamesByID: [100: "Desktop — Local"]
        )

        XCTAssertEqual(refined.count, 1)
        XCTAssertEqual(refined[0].windowName, "Desktop — Local")
    }

    func testFinderRefinementReplacesBrowserWhenCGTitleDoesNotMatchAX() {
        let windows = [makeFinderWindowInfo(title: "Desktop — Local", windowID: 100, isMain: false)]

        let refined = refineFinderWindows(
            windows,
            visibleCGWindowIDs: [100],
            cgWindowNamesByID: [100: "Finder"]
        )

        XCTAssertEqual(refined.count, 1)
        XCTAssertEqual(refined[0].windowName, "No Windows")
    }

    func testFinderRefinementReplacesBrowserWhenCGTitleIsMissing() {
        let windows = [makeFinderWindowInfo(title: "Desktop — Local", windowID: 100)]

        let refined = refineFinderWindows(
            windows,
            visibleCGWindowIDs: [100],
            cgWindowNamesByID: [100: ""]
        )

        XCTAssertEqual(refined.count, 1)
        XCTAssertEqual(refined[0].windowName, "No Windows")
    }

    func testFinderRefinementReplacesSingleOffSpaceBrowserWithNoWindowsPlaceholder() {
        let windows = [
            makeFinderWindowInfo(title: "Desktop — Local", windowID: 100, isOnScreen: false)
        ]

        let refined = refineFinderWindows(windows, visibleCGWindowIDs: [100])

        XCTAssertEqual(refined.count, 1)
        XCTAssertEqual(refined[0].windowName, "No Windows")
    }

    func testFinderRefinementReplacesRestoreRowWithoutMainWindow() {
        let windows = [
            makeFinderWindowInfo(title: "Desktop — Local", windowID: 100, isMain: false)
        ]

        let refined = refineFinderWindows(
            windows,
            visibleCGWindowIDs: [100],
            cgWindowNamesByID: [100: "Desktop — Local"]
        )

        XCTAssertEqual(refined.count, 1)
        XCTAssertEqual(refined[0].windowName, "No Windows")
    }

    func testFinderRefinementKeepsBrowserWithMainWindow() {
        let windows = [
            makeFinderWindowInfo(title: "Desktop — Local", windowID: 100, isMain: true)
        ]

        let refined = refineFinderWindows(
            windows,
            visibleCGWindowIDs: [100],
            cgWindowNamesByID: [100: "Desktop — Local"]
        )

        XCTAssertEqual(refined.count, 1)
        XCTAssertEqual(refined[0].windowName, "Desktop — Local")
    }

    func testFinderRefinementReplacesMainBrowserWithoutMatchingCGTitle() {
        let windows = [makeFinderWindowInfo(title: "Recents", windowID: 100, isMain: true)]

        let refined = refineFinderWindows(
            windows,
            visibleCGWindowIDs: [100],
            cgWindowNamesByID: [100: "Finder"]
        )

        XCTAssertEqual(refined.map(\.windowName), ["Recents"])
    }

    func testFinderRefinementKeepsTwoRecentsWindowsWithGenericCGTitle() {
        let windows = [
            makeFinderWindowInfo(
                title: "Recents",
                windowID: 100,
                bounds: CGRect(x: 40, y: 40, width: 900, height: 700),
                axIndex: 0,
                isMain: false
            ),
            makeFinderWindowInfo(
                title: "Recents",
                windowID: 200,
                bounds: CGRect(x: 980, y: 40, width: 900, height: 700),
                axIndex: 1,
                isMain: false
            )
        ]

        let refined = refineFinderWindows(
            windows,
            visibleCGWindowIDs: [100, 200],
            cgWindowNamesByID: [100: "Finder", 200: "Finder"]
        )

        XCTAssertEqual(refined.count, 2)
        XCTAssertEqual(Set(refined.map(\.windowID)), Set([100, 200]))
    }

    func testFinderRefinementKeepsMultipleBrowserWindows() {
        let windows = [
            makeFinderWindowInfo(title: "Downloads", windowID: 100, axIndex: 0, isMain: true),
            makeFinderWindowInfo(title: "Documents", windowID: 200, axIndex: 1, isMain: false)
        ]

        let refined = refineFinderWindows(windows, visibleCGWindowIDs: [100, 200])

        XCTAssertEqual(refined.map(\.windowName), ["Downloads", "Documents"])
    }

    func testFinderRefinementKeepsMultipleBrowserWindowsWhenNeitherIsMain() {
        let windows = [
            makeFinderWindowInfo(title: "Downloads", windowID: 100, axIndex: 0, isMain: false),
            makeFinderWindowInfo(title: "Documents", windowID: 200, axIndex: 1, isMain: false)
        ]

        let refined = refineFinderWindows(windows, visibleCGWindowIDs: [100, 200])

        XCTAssertEqual(refined.map(\.windowName), ["Downloads", "Documents"])
    }

    func testFinderRefinementLeavesNonFinderAppsUntouched() {
        let windows = [
            makeFinderWindowInfo(title: "Finder", windowID: 100),
            makeFinderWindowInfo(title: "Desktop — Local", windowID: 200)
        ]

        let refined = WindowEnumerator.refinedWindowsForApplication(
            windows,
            bundleIdentifier: "com.microsoft.VSCode"
        )

        XCTAssertEqual(refined.count, 2)
    }

    func testFinderRefinementCollapsesRowsSharingCaptureID() {
        let sharedBounds = CGRect(x: 40, y: 40, width: 900, height: 700)
        let windows = [
            makeFinderWindowInfo(title: "Desktop — Local", windowID: 555, bounds: sharedBounds, axIndex: 0),
            makeFinderWindowInfo(title: "Finder", windowID: 555, bounds: sharedBounds, axIndex: 1)
        ]

        let refined = refineFinderWindows(
            windows,
            visibleCGWindowIDs: [555],
            cgWindowNamesByID: [555: "Desktop — Local"]
        )

        XCTAssertEqual(refined.count, 1)
        XCTAssertEqual(refined[0].windowName, "Desktop — Local")
        XCTAssertEqual(refined[0].windowID, 555)
    }

    func testFinderRefinementDropsOverlappingUntitledShell() {
        let browserBounds = CGRect(x: 40, y: 40, width: 900, height: 700)
        let windows = [
            makeFinderWindowInfo(title: "Desktop — Local", windowID: 100, bounds: browserBounds, axIndex: 0),
            makeFinderWindowInfo(title: nil, windowID: 200, bounds: browserBounds, axIndex: 1)
        ]

        let refined = refineFinderWindows(
            windows,
            visibleCGWindowIDs: [100, 200],
            cgWindowNamesByID: [100: "Desktop — Local"]
        )

        XCTAssertEqual(refined.count, 1)
        XCTAssertEqual(refined[0].windowName, "Desktop — Local")
    }

    func testFinderPlaceholderMapsToWindowlessPreviewModel() {
        let placeholder = WindowEnumerator.finderWindowlessPlaceholder(
            from: makeFinderWindowInfo(title: "Desktop — Local", windowID: 100)
        )
        let model = WindowModel(from: placeholder)
        XCTAssertTrue(model.isWindowlessPlaceholder)
    }

    func testSyntheticWindowlessPlaceholderMapsToNoWindowsModel() {
        let pid: pid_t = 99_001
        let info = WindowInfo(
            windowID: PreviewIdentity.pseudoWindowID(
                ownerPID: pid,
                axIndex: 0,
                title: "No Windows",
                bounds: .zero
            ),
            ownerPID: pid,
            ownerBundleIdentifier: "com.apple.Safari",
            axIndex: 0,
            ownerName: "Safari",
            windowName: "No Windows",
            bounds: .zero,
            isOnScreen: false,
            isMinimized: false,
            isHidden: false,
            isMain: false,
            spaceID: nil,
            hasReliableWindowID: false
        )
        var model = WindowModel(from: info)
        model.subtitle = "No Windows"
        XCTAssertTrue(model.isWindowlessPlaceholder)
    }

    func testMergedWindowsPreservingPreviewsDropsRemovedSurface() {
        let pid: pid_t = 10_002
        let existing = WindowModel(windowID: 1, title: "One", ownerPID: pid)
        let fresh = WindowModel(windowID: 2, title: "Two", ownerPID: pid)

        let merged = WindowModel.mergedPreservingPreviews(fresh: [fresh], existing: [existing])

        XCTAssertEqual(merged.map(\.title), ["Two"])
    }

    func testRefinementKeepsSameTitleDifferentAxIndex() {
        let windows = [
            makeFinderWindowInfo(title: "Personal: New Tab", windowID: 100, axIndex: 0),
            makeFinderWindowInfo(title: "Personal: New Tab", windowID: 200, axIndex: 1)
        ]

        let refined = WindowEnumerator.refinedWindowsForApplication(
            windows,
            bundleIdentifier: "company.thebrowser.dia"
        )

        XCTAssertEqual(refined.count, 2)
    }

    func testMergedWindowsPreservingPreviewsDoesNotMergeByTitleAloneWhenAxIndexDiffers() {
        let pid: pid_t = 10_004
        let image = NSImage(size: NSSize(width: 12, height: 12))
        let existing = [
            WindowModel(
                windowID: 1,
                title: "Personal: New Tab",
                ownerPID: pid,
                axIndex: 0,
                previewImage: image
            ),
            WindowModel(
                windowID: 2,
                title: "Personal: New Tab",
                ownerPID: pid,
                axIndex: 1,
                previewImage: nil
            )
        ]
        let fresh = [
            WindowModel(windowID: 1, title: "Personal: New Tab", ownerPID: pid, axIndex: 0, previewImage: nil),
            WindowModel(windowID: 2, title: "Personal: New Tab", ownerPID: pid, axIndex: 1, previewImage: nil)
        ]

        let merged = WindowModel.mergedPreservingPreviews(fresh: fresh, existing: existing)

        XCTAssertTrue(merged[0].previewImage === image)
        XCTAssertNil(merged[1].previewImage)
    }

    func testPreviewIdentityDoesNotMatchSameTitleDifferentAxIndex() {
        let pid: pid_t = 12_345
        let lhs = PreviewIdentity(
            ownerPID: pid,
            bundleIdentifier: "company.thebrowser.dia",
            cgWindowID: 1,
            axIndex: 0,
            title: "Personal: New Tab",
            bounds: CGRect(x: 40, y: 40, width: 900, height: 700),
            hasReliableCGWindowID: false
        )
        let rhs = PreviewIdentity(
            ownerPID: pid,
            bundleIdentifier: "company.thebrowser.dia",
            cgWindowID: 2,
            axIndex: 1,
            title: "Personal: New Tab",
            bounds: CGRect(x: 60, y: 40, width: 900, height: 700),
            hasReliableCGWindowID: false
        )

        XCTAssertFalse(lhs.matches(rhs))
    }

    // MARK: - Helpers

    private func makeApp(name: String) -> ApplicationModel {
        makeApp(pid: pid_t.random(in: 1...10000), name: name)
    }

    private func refineFinderWindows(
        _ windows: [WindowInfo],
        visibleCGWindowIDs: Set<CGWindowID>? = nil,
        cgWindowNamesByID: [CGWindowID: String]? = nil
    ) -> [WindowInfo] {
        let visible = visibleCGWindowIDs ?? Set(windows.map(\.windowID))
        let cgNames = cgWindowNamesByID ?? {
            var names: [CGWindowID: String] = [:]
            for window in windows {
                names[window.windowID] = window.windowName ?? ""
            }
            return names
        }()
        return WindowEnumerator.refinedWindowsForApplication(
            windows,
            bundleIdentifier: WindowEnumerator.finderBundleIdentifier,
            visibleCGWindowIDsForOwner: visible,
            cgWindowNamesByID: cgNames
        )
    }

    private func makeFinderWindowInfo(
        title: String?,
        windowID: CGWindowID = 100,
        bounds: CGRect = CGRect(x: 40, y: 40, width: 900, height: 700),
        hasReliableWindowID: Bool = true,
        axIndex: Int = 0,
        isOnScreen: Bool = true,
        isHidden: Bool = false,
        isMain: Bool = true,
        isMinimized: Bool = false
    ) -> WindowInfo {
        WindowInfo(
            windowID: windowID,
            ownerPID: 501,
            ownerBundleIdentifier: WindowEnumerator.finderBundleIdentifier,
            axIndex: axIndex,
            ownerName: "Finder",
            windowName: title,
            bounds: bounds,
            isOnScreen: isOnScreen,
            isMinimized: isMinimized,
            isHidden: isHidden,
            isMain: isMain,
            spaceID: nil,
            hasReliableWindowID: hasReliableWindowID
        )
    }

    private func makeApp(pid: pid_t, name: String) -> ApplicationModel {
        ApplicationModel(
            pid: pid,
            bundleIdentifier: "com.test.\(name.lowercased())",
            name: name,
            icon: NSImage()
        )
    }

    private func makeUsagePreviewIdentity(
        windowID: CGWindowID,
        title: String,
        bundleIdentifier: String = "com.apple.Safari",
        ownerPID: pid_t = 12_345
    ) -> PreviewIdentity {
        PreviewIdentity(
            ownerPID: ownerPID,
            bundleIdentifier: bundleIdentifier,
            cgWindowID: windowID,
            title: title,
            bounds: CGRect(x: 40, y: 40, width: 800, height: 600),
            hasReliableCGWindowID: true
        )
    }
}
