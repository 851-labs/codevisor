import Foundation
import CodevisorTheming
import Observation

/// Persisted app settings: onboarding completion, whether to surface sessions
/// that were created outside Codevisor (imported via `session/list`), and the
/// appearance/theme selection.
public struct AppSettings: Sendable, Codable, Equatable {
    public static let defaultNotificationSoundPath = "/System/Library/Sounds/Glass.aiff"

    public var hasCompletedOnboarding: Bool
    /// The app version whose launch last confirmed (or walked the user
    /// through) the system permissions Computer Use needs. When an update
    /// arrives and permissions are missing, the standalone permissions gate
    /// shows once for the new version.
    public var permissionsReviewedVersion: String?
    /// The user chose "Set Up Later": Computer Use is disabled and no launch
    /// gate nags again. Cleared when permissions setup completes (from the
    /// MCP settings inline flow or a later onboarding pass).
    public var permissionsSetupSkipped: Bool
    /// How far onboarding got, so a restart part-way through (granting
    /// Screen Recording asks for one) resumes on the same step instead of
    /// starting over. Cleared when onboarding completes.
    public var onboardingStep: Int?
    /// The permissions review was presented and the user has not finished it
    /// yet. Granting Screen Recording restarts the app mid-review, so the
    /// dialog has to come back — even once everything is granted — until the
    /// user actually closes it. Cleared by Continue or Set Up Later.
    public var permissionsReviewInProgress: Bool
    public var importExternalSessions: Bool
    /// Whether this device may send anonymous product usage events. Content
    /// such as prompts, responses, code, paths, and terminal commands must
    /// never be included in those events.
    public var shareAnalytics: Bool
    /// Whether this installation may send privacy-filtered native crash and
    /// allowlisted internal error reports to Sentry.
    public var shareCrashReports: Bool
    /// Opts this installation into signed Alpha builds in addition to Stable.
    public var alphaUpdatesEnabled: Bool
    /// Whether ⌘Q asks "Are you sure you want to quit?" first. A stray ⌘Q
    /// (next to ⌘W) tears down every open terminal and agent view at once, so
    /// this defaults on; the alert's "Do not ask me again" turns it off.
    public var confirmBeforeQuitting: Bool
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
        permissionsReviewedVersion: String? = nil,
        permissionsSetupSkipped: Bool = false,
        onboardingStep: Int? = nil,
        permissionsReviewInProgress: Bool = false,
        importExternalSessions: Bool = false,
        shareAnalytics: Bool = false,
        shareCrashReports: Bool = false,
        alphaUpdatesEnabled: Bool = false,
        confirmBeforeQuitting: Bool = true,
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
        self.permissionsReviewedVersion = permissionsReviewedVersion
        self.permissionsSetupSkipped = permissionsSetupSkipped
        self.onboardingStep = onboardingStep
        self.permissionsReviewInProgress = permissionsReviewInProgress
        self.importExternalSessions = importExternalSessions
        self.shareAnalytics = shareAnalytics
        self.shareCrashReports = shareCrashReports
        self.alphaUpdatesEnabled = alphaUpdatesEnabled
        self.confirmBeforeQuitting = confirmBeforeQuitting
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
        case hasCompletedOnboarding, permissionsReviewedVersion, permissionsSetupSkipped
        case onboardingStep, permissionsReviewInProgress
        case importExternalSessions, shareAnalytics
        case shareCrashReports, alphaUpdatesEnabled
        /// Read-only migration key written by the former custom updater.
        case betaUpdatesEnabled
        case confirmBeforeQuitting
        case disabledHarnessIds
        case themeMode, lightThemeId, darkThemeId
        case notificationsEnabled, systemNotificationsEnabled, notificationSoundsEnabled
        case chatFinishedSoundPath, actionRequiredSoundPath
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        permissionsReviewedVersion = try container.decodeIfPresent(String.self, forKey: .permissionsReviewedVersion)
        permissionsSetupSkipped = try container.decodeIfPresent(Bool.self, forKey: .permissionsSetupSkipped) ?? false
        onboardingStep = try container.decodeIfPresent(Int.self, forKey: .onboardingStep)
        permissionsReviewInProgress =
            try container.decodeIfPresent(
                Bool.self,
                forKey: .permissionsReviewInProgress
            ) ?? false
        importExternalSessions = try container.decodeIfPresent(Bool.self, forKey: .importExternalSessions) ?? false
        // Existing installations completed onboarding before this preference
        // existed. Enable analytics for that migration cohort; fresh installs
        // remain disabled until the final onboarding step is completed.
        shareAnalytics =
            try container.decodeIfPresent(Bool.self, forKey: .shareAnalytics)
            ?? hasCompletedOnboarding
        // Native diagnostics are a separate data class. Never extend an older
        // analytics choice to Sentry without a new, explicit decision.
        shareCrashReports = try container.decodeIfPresent(Bool.self, forKey: .shareCrashReports) ?? false
        alphaUpdatesEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .alphaUpdatesEnabled)
            ?? container.decodeIfPresent(Bool.self, forKey: .betaUpdatesEnabled)
            ?? false
        confirmBeforeQuitting = try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeQuitting) ?? true
        disabledHarnessIds = try container.decodeIfPresent(Set<String>.self, forKey: .disabledHarnessIds) ?? []
        themeMode = try container.decodeIfPresent(ThemeMode.self, forKey: .themeMode) ?? .system
        lightThemeId = try container.decodeIfPresent(String.self, forKey: .lightThemeId) ?? ThemeCatalog.systemLightID
        darkThemeId = try container.decodeIfPresent(String.self, forKey: .darkThemeId) ?? ThemeCatalog.systemDarkID
        notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        systemNotificationsEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .systemNotificationsEnabled) ?? true
        notificationSoundsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationSoundsEnabled) ?? true
        chatFinishedSoundPath =
            try container.decodeIfPresent(
                String.self,
                forKey: .chatFinishedSoundPath
            ) ?? Self.defaultNotificationSoundPath
        actionRequiredSoundPath =
            try container.decodeIfPresent(
                String.self,
                forKey: .actionRequiredSoundPath
            ) ?? Self.defaultNotificationSoundPath
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
        try container.encodeIfPresent(permissionsReviewedVersion, forKey: .permissionsReviewedVersion)
        try container.encode(permissionsSetupSkipped, forKey: .permissionsSetupSkipped)
        try container.encodeIfPresent(onboardingStep, forKey: .onboardingStep)
        try container.encode(permissionsReviewInProgress, forKey: .permissionsReviewInProgress)
        try container.encode(importExternalSessions, forKey: .importExternalSessions)
        try container.encode(shareAnalytics, forKey: .shareAnalytics)
        try container.encode(shareCrashReports, forKey: .shareCrashReports)
        try container.encode(alphaUpdatesEnabled, forKey: .alphaUpdatesEnabled)
        try container.encode(confirmBeforeQuitting, forKey: .confirmBeforeQuitting)
        try container.encode(disabledHarnessIds, forKey: .disabledHarnessIds)
        try container.encode(themeMode, forKey: .themeMode)
        try container.encode(lightThemeId, forKey: .lightThemeId)
        try container.encode(darkThemeId, forKey: .darkThemeId)
        try container.encode(notificationsEnabled, forKey: .notificationsEnabled)
        try container.encode(systemNotificationsEnabled, forKey: .systemNotificationsEnabled)
        try container.encode(notificationSoundsEnabled, forKey: .notificationSoundsEnabled)
        try container.encode(chatFinishedSoundPath, forKey: .chatFinishedSoundPath)
        try container.encode(actionRequiredSoundPath, forKey: .actionRequiredSoundPath)
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
    public var permissionsReviewedVersion: String? { settings.permissionsReviewedVersion }
    public var permissionsSetupSkipped: Bool { settings.permissionsSetupSkipped }
    public var onboardingStep: Int? { settings.onboardingStep }
    public var permissionsReviewInProgress: Bool { settings.permissionsReviewInProgress }
    public var importExternalSessions: Bool { settings.importExternalSessions }
    public var shareAnalytics: Bool { settings.shareAnalytics }
    public var shareCrashReports: Bool { settings.shareCrashReports }
    public var alphaUpdatesEnabled: Bool { settings.alphaUpdatesEnabled }
    public var confirmBeforeQuitting: Bool { settings.confirmBeforeQuitting }

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
        settings.onboardingStep = nil
        persist()
    }

    /// Records that the given app version confirmed (or walked the user
    /// through) the Computer Use system permissions.
    public func setPermissionsReviewedVersion(_ version: String) {
        settings.permissionsReviewedVersion = version
        persist()
    }

    public func setPermissionsSetupSkipped(_ value: Bool) {
        settings.permissionsSetupSkipped = value
        persist()
    }

    /// Remembers how far onboarding got so a mid-flow restart resumes there.
    public func setOnboardingStep(_ step: Int?) {
        settings.onboardingStep = step
        persist()
    }

    /// Marks the permissions review open (the dialog returns after a restart)
    /// or finished (the user pressed Continue or Set Up Later).
    public func setPermissionsReviewInProgress(_ value: Bool) {
        settings.permissionsReviewInProgress = value
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

    /// Updates the privacy preference used as the single gate for diagnostics.
    public func setShareCrashReports(_ value: Bool) {
        settings.shareCrashReports = value
        persist()
    }

    public func setAlphaUpdatesEnabled(_ value: Bool) {
        settings.alphaUpdatesEnabled = value
        persist()
    }

    /// Turns the ⌘Q confirmation alert on or off. Off is what the alert's
    /// "Do not ask me again" checkbox records; Settings can turn it back on.
    public func setConfirmBeforeQuitting(_ value: Bool) {
        settings.confirmBeforeQuitting = value
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
            Log.persistence.error(
                "Failed to save \(self.key, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
