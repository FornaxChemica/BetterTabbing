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

    func testMergedWindowsPreservingPreviewsDropsRemovedSurface() {
        let pid: pid_t = 10_002
        let existing = WindowModel(windowID: 1, title: "One", ownerPID: pid)
        let fresh = WindowModel(windowID: 2, title: "Two", ownerPID: pid)

        let merged = WindowModel.mergedPreservingPreviews(fresh: [fresh], existing: [existing])

        XCTAssertEqual(merged.map(\.title), ["Two"])
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
}
