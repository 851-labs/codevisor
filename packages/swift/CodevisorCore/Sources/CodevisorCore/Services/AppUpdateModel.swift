import Foundation
import Observation

/// The small, framework-independent portion of app update state consumed by
/// Codevisor's existing sidebar and composer. Sparkle owns discovery,
/// verification, installation, rollback, release notes, and relaunching.
public struct AppUpdateRelease: Equatable, Sendable {
  public var version: String
  public var releasePageURL: URL?

  public init(version: String, releasePageURL: URL? = nil) {
    self.version = version
    self.releasePageURL = releasePageURL
  }
}

@MainActor
@Observable
public final class AppUpdateModel {
  public enum Phase: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(AppUpdateRelease)
    case updating(AppUpdateRelease)
    case failed(release: AppUpdateRelease?, message: String)
  }

  public private(set) var phase: Phase = .idle
  /// Download progress (0...1) while the update is downloading; nil when the
  /// current step has no measurable progress.
  public private(set) var progress: Double?
  /// What the update is doing right now ("Downloading…", "Waiting for 2
  /// chats to finish…"); nil outside an install.
  public private(set) var statusMessage: String?
  public let currentVersion: String
  public let currentBuildNumber: Int?
  public private(set) var allowsAlphaUpdates: Bool

  /// Installed by the app target's Sparkle coordinator. The boolean is true
  /// for a user-initiated check and false for a quiet background check;
  /// both report through this model — Sparkle never shows its own UI.
  public var checkHandler: (@MainActor (_ userInitiated: Bool) async -> Void)?
  /// Installs the release behind the banner headlessly: download, drain the
  /// local server's chats, install, relaunch — progress lands in this model.
  public var installHandler: (@MainActor (AppUpdateRelease) async -> Void)?
  /// The same headless cycle, started without a known release: used when a
  /// remote client asked this machine's server to update itself, so the
  /// feed check and the install run as one session.
  public var unattendedInstallHandler: (@MainActor () async -> Void)?
  /// Resets Sparkle's update cycle after the user changes channels.
  public var channelChangeHandler: (@MainActor (_ allowsAlpha: Bool) -> Void)?

  public init(
    currentVersion: String,
    currentBuildNumber: Int? = nil,
    allowsAlphaUpdates: Bool = false
  ) {
    self.currentVersion = currentVersion
    self.currentBuildNumber = currentBuildNumber
    self.allowsAlphaUpdates = allowsAlphaUpdates
  }

  public func setAllowsAlphaUpdates(_ value: Bool) {
    allowsAlphaUpdates = value
    channelChangeHandler?(value)
  }

  public var availableRelease: AppUpdateRelease? {
    switch phase {
    case let .available(release), let .updating(release):
      return release
    case let .failed(release, _):
      return release
    case .idle, .checking, .upToDate:
      return nil
    }
  }

  public var isUpdating: Bool {
    if case .updating = phase { return true }
    return false
  }

  public var failureMessage: String? {
    if case let .failed(_, message) = phase { return message }
    return nil
  }

  public func checkForUpdates() async {
    guard let checkHandler else { return }
    phase = .checking
    await checkHandler(true)
  }

  public func checkForUpdatesInBackground() async {
    guard let checkHandler else { return }
    await checkHandler(false)
  }

  public func installUpdate() async {
    guard let release = availableRelease, let installHandler else { return }
    await installHandler(release)
  }

  /// Installs the newest release without any Sparkle UI, then relaunches.
  /// Falls back to the interactive check when no unattended handler is
  /// installed (development builds have no Sparkle coordinator).
  public func installUpdateUnattended() async {
    guard let unattendedInstallHandler else {
      await checkForUpdates()
      return
    }
    phase = .checking
    await unattendedInstallHandler()
  }

  public func reportAvailable(version: String, releasePageURL: URL?) {
    let release = AppUpdateRelease(version: version, releasePageURL: releasePageURL)
    if case let .failed(existing, message) = phase, existing?.version == version {
      phase = .failed(release: release, message: message)
    } else {
      phase = .available(release)
    }
  }

  public func reportUpToDate() {
    phase = .upToDate
    reportProgress(nil)
  }

  public func reportInstalling(version: String, releasePageURL: URL?) {
    phase = .updating(
      AppUpdateRelease(version: version, releasePageURL: releasePageURL)
    )
  }

  /// A step of the install: `progress` is the download fraction when known.
  public func reportProgress(_ message: String?, fraction: Double? = nil) {
    statusMessage = message
    progress = fraction.map { min(1, max(0, $0)) }
  }

  public func reportFailure(_ message: String) {
    phase = .failed(release: availableRelease, message: message)
    reportProgress(nil)
  }

  public func reportIdle() {
    phase = .idle
    reportProgress(nil)
  }

  public static func bundleVersion(_ bundle: Bundle = .main) -> String {
    (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
  }

  public static func bundleBuildNumber(_ bundle: Bundle = .main) -> Int? {
    guard let value = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
      return nil
    }
    return Int(value)
  }

  public static func bundleSourceRevision(_ bundle: Bundle = .main) -> String? {
    guard let value = bundle.object(forInfoDictionaryKey: "CodevisorSourceRevision") as? String,
      !value.isEmpty, value != "unknown"
    else { return nil }
    return value
  }
}
