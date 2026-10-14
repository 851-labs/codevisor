import Foundation
import Observation

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
  public private(set) var progress: Double?
  public private(set) var statusMessage: String?
  public let currentVersion: String
  public let currentBuildNumber: Int?
  public private(set) var allowsAlphaUpdates: Bool

  public var checkHandler: (@MainActor () async -> Void)?
  public var installHandler: (@MainActor (AppUpdateRelease) async -> Void)?
  public var unattendedInstallHandler: (@MainActor () async -> Void)?
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

  public var displayedCurrentVersion: String {
    Self.displayedVersion(
      currentVersion,
      buildNumber: currentBuildNumber,
      usesAlphaChannel: allowsAlphaUpdates
    )
  }

  public static func displayedVersion(
    _ version: String,
    buildNumber: Int?,
    usesAlphaChannel: Bool
  ) -> String {
    guard usesAlphaChannel, let buildNumber, !version.contains("-") else { return version }
    return "\(version)-alpha.\(buildNumber)"
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
    guard !isUpdating, let checkHandler else { return }
    reportProgress(nil)
    phase = .checking
    await checkHandler()
  }

  public func checkForUpdatesInBackground() async {
    guard !isUpdating, let checkHandler else { return }
    await checkHandler()
  }

  public func resetFailure() {
    guard case let .failed(release, _) = phase else { return }
    phase = release.map(Phase.available) ?? .idle
    reportProgress(nil)
  }

  public func installUpdate() async {
    guard let release = availableRelease, let installHandler else { return }
    await installHandler(release)
  }

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

  public func reportProgress(_ message: String?, fraction: Double? = nil) {
    statusMessage = message
    progress = fraction.map { min(1, max(0, $0)) }
  }

  public func reportFailure(_ message: String) {
    phase = .failed(release: availableRelease, message: message)
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
