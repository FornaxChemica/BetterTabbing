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

    // MARK: - Helpers

    private func makeApp(name: String) -> ApplicationModel {
        makeApp(pid: pid_t.random(in: 1...10000), name: name)
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
