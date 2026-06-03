import Foundation

struct UserPreferences: Codable {
    // Activation
    var activationModifier: ModifierKey = .option
    var useSystemShortcut: Bool = false  // If true, use CMD+TAB instead of OPTION+TAB

    // Behavior
    var showAllSpaces: Bool = false
    var showMinimizedWindows: Bool = true
    var hideSystemApps: Bool = true

    // Appearance
    var theme: Theme = .system
    var windowSize: WindowSize = .medium

    // Quit Hold
    var quitHoldDuration: Double = 2.0  // seconds (0.5 - 5.0)

    // Launch
    var launchAtLogin: Bool = false

    // Excluded Apps
    var excludedBundleIDs: [String] = []

    // Feature modules
    var modules = ModuleSettings()

    // Keyboard shortcuts
    var shortcuts = ShortcutPreferences()

    struct ModuleSettings: Codable, Equatable {
        var windowSlotsEnabled: Bool = true
        var windowHistoryEnabled: Bool = true
        var workspaceSwitcherEnabled: Bool = true
        var resourceMonitorEnabled: Bool = true
    }

    enum Theme: String, Codable, CaseIterable {
        case system
        case light
        case dark

        var displayName: String {
            rawValue.capitalized
        }
    }

    enum WindowSize: String, Codable, CaseIterable {
        case compact
        case medium
        case large

        var dimensions: CGSize {
            switch self {
            case .compact: return CGSize(width: 500, height: 300)
            case .medium: return CGSize(width: 680, height: 400)
            case .large: return CGSize(width: 860, height: 500)
            }
        }

        var displayName: String {
            rawValue.capitalized
        }
    }

    // MARK: - Persistence

    private static let key = "WindowLensPreferences"
    private static let legacyKey = "BetterTabbingPreferences"
    private static let legacyBundleIdentifier = "com.fornaxchemica.bettertabbing"

    static func load() -> UserPreferences {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key),
           let prefs = try? JSONDecoder().decode(UserPreferences.self, from: data) {
            return prefs
        }

        if let legacyData = defaults.data(forKey: legacyKey),
           let legacyPrefs = try? JSONDecoder().decode(UserPreferences.self, from: legacyData) {
            defaults.set(legacyData, forKey: key)
            return legacyPrefs
        }

        if let migratedPrefs = migrateFromLegacyDefaults(to: defaults) {
            return migratedPrefs
        }

        return UserPreferences()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: UserPreferences.key)
    }

    private static func migrateFromLegacyDefaults(to defaults: UserDefaults) -> UserPreferences? {
        let legacyDefaults = UserDefaults(suiteName: legacyBundleIdentifier)
        let candidates: [Data?] = [
            legacyDefaults?.data(forKey: key),
            legacyDefaults?.data(forKey: legacyKey),
            legacyPersistentDomainData(forKey: key),
            legacyPersistentDomainData(forKey: legacyKey)
        ]

        for candidate in candidates {
            guard let data = candidate,
                  let prefs = try? JSONDecoder().decode(UserPreferences.self, from: data) else {
                continue
            }

            defaults.set(data, forKey: key)
            print("[UserPreferences] Migrated preferences from legacy BetterTabbing defaults")
            return prefs
        }

        return nil
    }

    private static func legacyPersistentDomainData(forKey key: String) -> Data? {
        UserDefaults.standard
            .persistentDomain(forName: legacyBundleIdentifier)?[key] as? Data
    }
}
