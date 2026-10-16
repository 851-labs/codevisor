import Foundation
import Observation

public struct AppSettings: Sendable, Codable, Equatable {
  public static let defaultNotificationSoundPath = "/System/Library/Sounds/Glass.aiff"

  public var hasCompletedOnboarding: Bool
  public var permissionsReviewedVersion: String?
  public var permissionsSetupSkipped: Bool
  public var onboardingStep: Int?
  public var permissionsReviewInProgress: Bool
  public var importExternalSessions: Bool
  public var shareAnalytics: Bool
  public var shareCrashReports: Bool
  public var alphaUpdatesEnabled: Bool
  public var confirmBeforeQuitting: Bool
  public var confirmBeforeClosingWorkingChat: Bool
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
    confirmBeforeClosingWorkingChat: Bool = true,
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
    self.confirmBeforeClosingWorkingChat = confirmBeforeClosingWorkingChat
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
    case betaUpdatesEnabled
    case confirmBeforeQuitting, confirmBeforeClosingWorkingChat
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
    shareAnalytics =
      try container.decodeIfPresent(Bool.self, forKey: .shareAnalytics)
      ?? hasCompletedOnboarding
    shareCrashReports = try container.decodeIfPresent(Bool.self, forKey: .shareCrashReports) ?? false
    alphaUpdatesEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .alphaUpdatesEnabled)
      ?? container.decodeIfPresent(Bool.self, forKey: .betaUpdatesEnabled)
      ?? false
    confirmBeforeQuitting = try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeQuitting) ?? true
    confirmBeforeClosingWorkingChat =
      try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeClosingWorkingChat) ?? true
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
    try container.encode(confirmBeforeClosingWorkingChat, forKey: .confirmBeforeClosingWorkingChat)
    try container.encode(notificationsEnabled, forKey: .notificationsEnabled)
    try container.encode(systemNotificationsEnabled, forKey: .systemNotificationsEnabled)
    try container.encode(notificationSoundsEnabled, forKey: .notificationSoundsEnabled)
    try container.encode(chatFinishedSoundPath, forKey: .chatFinishedSoundPath)
    try container.encode(actionRequiredSoundPath, forKey: .actionRequiredSoundPath)
  }
}

@MainActor
@Observable
public final class AppSettingsModel {
  public private(set) var settings: AppSettings
  private let store: any PersistenceStore
  private let key = "settings"

  public convenience init(store: any PersistenceStore) {
    self.init(store: store, settings: Self.loadSettings(from: store))
  }

  public convenience init(store: any PersistenceStore, launchSnapshot: ClientLaunchSnapshot?) {
    self.init(store: store, settings: launchSnapshot?.settings ?? Self.loadSettings(from: store))
  }

  private init(store: any PersistenceStore, settings: AppSettings) {
    self.store = store
    self.settings = settings
  }

  nonisolated static func loadSettings(from store: any PersistenceStore) -> AppSettings {
    guard let data = store.loadData(forKey: "settings") else { return AppSettings() }
    do {
      return try JSONDecoder().decode(AppSettings.self, from: data)
    } catch {
      handleCorruptPayload(
        store: store,
        key: "settings",
        data: data,
        error: error,
        reportTitle: "Couldn't Read Your Settings",
        reportMessage: "Codevisor is starting with default settings. A backup of the old file was kept."
      )
      return AppSettings()
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
  public var confirmBeforeClosingWorkingChat: Bool { settings.confirmBeforeClosingWorkingChat }
  public var shouldConfirmBeforeQuitting: Bool {
    settings.hasCompletedOnboarding && settings.confirmBeforeQuitting
  }

  public func completeOnboarding(importExternalSessions: Bool) {
    settings.hasCompletedOnboarding = true
    settings.importExternalSessions = importExternalSessions
    settings.onboardingStep = nil
    persist()
  }

  public func setPermissionsReviewedVersion(_ version: String) {
    settings.permissionsReviewedVersion = version
    persist()
  }

  public func setPermissionsSetupSkipped(_ value: Bool) {
    settings.permissionsSetupSkipped = value
    persist()
  }

  public func setOnboardingStep(_ step: Int?) {
    settings.onboardingStep = step
    persist()
  }

  public func setPermissionsReviewInProgress(_ value: Bool) {
    settings.permissionsReviewInProgress = value
    persist()
  }

  public func setImportExternalSessions(_ value: Bool) {
    settings.importExternalSessions = value
    persist()
  }

  public func setShareAnalytics(_ value: Bool) {
    settings.shareAnalytics = value
    persist()
  }

  public func setShareCrashReports(_ value: Bool) {
    settings.shareCrashReports = value
    persist()
  }

  public func setAlphaUpdatesEnabled(_ value: Bool) {
    settings.alphaUpdatesEnabled = value
    persist()
  }

  public func setConfirmBeforeQuitting(_ value: Bool) {
    settings.confirmBeforeQuitting = value
    persist()
  }

  public func setConfirmBeforeClosingWorkingChat(_ value: Bool) {
    settings.confirmBeforeClosingWorkingChat = value
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
