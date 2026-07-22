import Foundation
import CodevisorTheming
import Observation

/// Persisted app settings: onboarding completion, whether to surface sessions
/// that were created outside Codevisor (imported via `session/list`), and the
/// appearance/theme selection.
public struct AppSettings: Sendable, Codable, Equatable {
    public static let defaultNotificationSoundPath = "/System/Library/Sounds/Glass.aiff"

    public var hasCompletedOnboarding: Bool
    public var importExternalSessions: Bool
    /// Whether this device may send anonymous product usage and diagnostic
    /// events. Content such as prompts, responses, code, paths, and terminal
    /// commands must never be included in those events.
    public var shareAnalytics: Bool
    /// Opts this installation into GitHub prerelease builds. Stable remains
    /// the default so existing and newly installed clients never follow RCs
    /// unless the user explicitly enables them.
    public var betaUpdatesEnabled: Bool
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
    /// Chat attention preferences are local to this device. Keeping them out
    /// of server state is intentional: a future iPhone client can choose its
    /// own sounds while a server-side presence coordinator chooses which
    /// active device receives each event.
    public var notificationsEnabled: Bool
    public var systemNotificationsEnabled: Bool
    public var notificationSoundsEnabled: Bool
    public var chatFinishedSoundPath: String
    public var actionRequiredSoundPath: String

    public init(
        hasCompletedOnboarding: Bool = false,
        importExternalSessions: Bool = false,
        shareAnalytics: Bool = false,
        betaUpdatesEnabled: Bool = false,
        disabledHarnessIds: Set<String> = [],
        themeMode: ThemeMode = .system,
        lightThemeId: String = ThemeCatalog.systemLightID,
        darkThemeId: String = ThemeCatalog.systemDarkID,
        notificationsEnabled: Bool = true,
        systemNotificationsEnabled: Bool = true,
        notificationSoundsEnabled: Bool = true,
        chatFinishedSoundPath: String = AppSettings.defaultNotificationSoundPath,
        actionRequiredSoundPath: String = AppSettings.defaultNotificationSoundPath
    ) {
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.importExternalSessions = importExternalSessions
        self.shareAnalytics = shareAnalytics
        self.betaUpdatesEnabled = betaUpdatesEnabled
        self.disabledHarnessIds = disabledHarnessIds
        self.themeMode = themeMode
        self.lightThemeId = lightThemeId
        self.darkThemeId = darkThemeId
        self.notificationsEnabled = notificationsEnabled
        self.systemNotificationsEnabled = systemNotificationsEnabled
        self.notificationSoundsEnabled = notificationSoundsEnabled
        self.chatFinishedSoundPath = chatFinishedSoundPath
        self.actionRequiredSoundPath = actionRequiredSoundPath
    }

    private enum CodingKeys: String, CodingKey {
        case hasCompletedOnboarding, importExternalSessions, shareAnalytics, betaUpdatesEnabled
        case disabledHarnessIds
        case themeMode, lightThemeId, darkThemeId
        case notificationsEnabled, systemNotificationsEnabled, notificationSoundsEnabled
        case chatFinishedSoundPath, actionRequiredSoundPath
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        importExternalSessions = try container.decodeIfPresent(Bool.self, forKey: .importExternalSessions) ?? false
        // Existing installations completed onboarding before this preference
        // existed. Enable analytics for that migration cohort; fresh installs
        // remain disabled until the final onboarding step is completed.
        shareAnalytics = try container.decodeIfPresent(Bool.self, forKey: .shareAnalytics)
            ?? hasCompletedOnboarding
        betaUpdatesEnabled = try container.decodeIfPresent(Bool.self, forKey: .betaUpdatesEnabled) ?? false
        disabledHarnessIds = try container.decodeIfPresent(Set<String>.self, forKey: .disabledHarnessIds) ?? []
        themeMode = try container.decodeIfPresent(ThemeMode.self, forKey: .themeMode) ?? .system
        lightThemeId = try container.decodeIfPresent(String.self, forKey: .lightThemeId) ?? ThemeCatalog.systemLightID
        darkThemeId = try container.decodeIfPresent(String.self, forKey: .darkThemeId) ?? ThemeCatalog.systemDarkID
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        systemNotificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .systemNotificationsEnabled) ?? true
        notificationSoundsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationSoundsEnabled) ?? true
        chatFinishedSoundPath = try container.decodeIfPresent(
            String.self,
            forKey: .chatFinishedSoundPath
        ) ?? Self.defaultNotificationSoundPath
        actionRequiredSoundPath = try container.decodeIfPresent(
            String.self,
            forKey: .actionRequiredSoundPath
        ) ?? Self.defaultNotificationSoundPath
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
        if let data = store.loadData(forKey: "settings") {
            do {
                settings = try JSONDecoder().decode(AppSettings.self, from: data)
            } catch {
                settings = AppSettings()
                handleCorruptPayload(
                    store: store,
                    key: "settings",
                    data: data,
                    error: error,
                    reportTitle: "Couldn't Read Your Settings",
                    reportMessage: "Codevisor is starting with default settings. A backup of the old file was kept."
                )
            }
        } else {
            settings = AppSettings()
        }
    }

    public var hasCompletedOnboarding: Bool { settings.hasCompletedOnboarding }
    public var importExternalSessions: Bool { settings.importExternalSessions }
    public var shareAnalytics: Bool { settings.shareAnalytics }
    public var betaUpdatesEnabled: Bool { settings.betaUpdatesEnabled }

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

    /// Updates the privacy preference used as the single gate for analytics.
    public func setShareAnalytics(_ value: Bool) {
        settings.shareAnalytics = value
        persist()
    }

    public func setBetaUpdatesEnabled(_ value: Bool) {
        settings.betaUpdatesEnabled = value
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

    public func setNotificationsEnabled(_ value: Bool) {
        settings.notificationsEnabled = value
        persist()
    }

    public func setSystemNotificationsEnabled(_ value: Bool) {
        settings.systemNotificationsEnabled = value
        persist()
    }

    public func setNotificationSoundsEnabled(_ value: Bool) {
        settings.notificationSoundsEnabled = value
        persist()
    }

    public func setChatFinishedSoundPath(_ path: String) {
        settings.chatFinishedSoundPath = path
        persist()
    }

    public func setActionRequiredSoundPath(_ path: String) {
        settings.actionRequiredSoundPath = path
        persist()
    }

    /// Resets settings to defaults (re-triggers onboarding).
    public func reset() {
        settings = AppSettings()
        persist()
    }

    private func persist() {
        do {
            try store.saveData(JSONEncoder().encode(settings), forKey: key)
        } catch {
            Log.persistence.error("Failed to save \(self.key, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
