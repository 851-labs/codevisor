import Foundation
import HerdManTheming
import Observation

/// Persisted app settings: onboarding completion, whether to surface sessions
/// that were created outside HerdMan (imported via `session/list`), and the
/// appearance/theme selection.
public struct AppSettings: Sendable, Codable, Equatable {
    public var hasCompletedOnboarding: Bool
    public var importExternalSessions: Bool
    /// Harness ids the user has explicitly turned off. A harness is "enabled"
    /// (shown in the composer picker) when its id is not in this set, so the
    /// default — an empty set — enables every installed harness.
    public var disabledHarnessIds: Set<String>
    /// Appearance: force light/dark or follow the OS.
    public var themeMode: ThemeMode
    /// The theme id used when the effective appearance is light/dark. The
    /// defaults are the system entries, which render the stock Apple look.
    public var lightThemeId: String
    public var darkThemeId: String

    public init(
        hasCompletedOnboarding: Bool = false,
        importExternalSessions: Bool = false,
        disabledHarnessIds: Set<String> = [],
        themeMode: ThemeMode = .system,
        lightThemeId: String = ThemeCatalog.systemLightID,
        darkThemeId: String = ThemeCatalog.systemDarkID
    ) {
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.importExternalSessions = importExternalSessions
        self.disabledHarnessIds = disabledHarnessIds
        self.themeMode = themeMode
        self.lightThemeId = lightThemeId
        self.darkThemeId = darkThemeId
    }

    private enum CodingKeys: String, CodingKey {
        case hasCompletedOnboarding, importExternalSessions, disabledHarnessIds
        case themeMode, lightThemeId, darkThemeId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        importExternalSessions = try container.decodeIfPresent(Bool.self, forKey: .importExternalSessions) ?? false
        disabledHarnessIds = try container.decodeIfPresent(Set<String>.self, forKey: .disabledHarnessIds) ?? []
        themeMode = try container.decodeIfPresent(ThemeMode.self, forKey: .themeMode) ?? .system
        lightThemeId = try container.decodeIfPresent(String.self, forKey: .lightThemeId) ?? ThemeCatalog.systemLightID
        darkThemeId = try container.decodeIfPresent(String.self, forKey: .darkThemeId) ?? ThemeCatalog.systemDarkID
    }
}

/// Observable, persisted settings model.
@MainActor
@Observable
public final class AppSettingsModel {
    public private(set) var settings: AppSettings
    private let store: any PersistenceStore
    private let key = "settings"

    public init(store: any PersistenceStore) {
        self.store = store
        if let data = store.loadData(forKey: key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    public var hasCompletedOnboarding: Bool { settings.hasCompletedOnboarding }
    public var importExternalSessions: Bool { settings.importExternalSessions }

    /// Whether a harness is enabled (not turned off by the user).
    public func isHarnessEnabled(_ id: String) -> Bool {
        !settings.disabledHarnessIds.contains(id)
    }

    /// Enables or disables a harness, persisting the change.
    public func setHarness(_ id: String, enabled: Bool) {
        if enabled {
            settings.disabledHarnessIds.remove(id)
        } else {
            settings.disabledHarnessIds.insert(id)
        }
        persist()
    }

    /// Filters discovered harnesses down to the enabled ones.
    public func enabledHarnesses(_ harnesses: [String]) -> [String] {
        harnesses.filter(isHarnessEnabled)
    }

    /// Records the result of onboarding.
    public func completeOnboarding(importExternalSessions: Bool) {
        settings.hasCompletedOnboarding = true
        settings.importExternalSessions = importExternalSessions
        persist()
    }

    public func setImportExternalSessions(_ value: Bool) {
        settings.importExternalSessions = value
        persist()
    }

    public func setThemeMode(_ mode: ThemeMode) {
        settings.themeMode = mode
        persist()
    }

    public func setLightThemeId(_ id: String) {
        settings.lightThemeId = id
        persist()
    }

    public func setDarkThemeId(_ id: String) {
        settings.darkThemeId = id
        persist()
    }

    /// Resets settings to defaults (re-triggers onboarding).
    public func reset() {
        settings = AppSettings()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? store.saveData(data, forKey: key)
    }
}
