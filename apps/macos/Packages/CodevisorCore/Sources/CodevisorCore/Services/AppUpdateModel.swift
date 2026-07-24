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
    public let currentVersion: String
    public let currentBuildNumber: Int?
    public private(set) var allowsAlphaUpdates: Bool

    /// Installed by the app target's Sparkle coordinator. The boolean is true
    /// for a user-initiated check (show Sparkle's native UI) and false for a
    /// quiet information check used to drive the sidebar banner.
    public var checkHandler: (@MainActor (_ userInitiated: Bool) async -> Void)?
    /// Presents Sparkle's native update UI for the release behind the banner.
    public var installHandler: (@MainActor (AppUpdateRelease) async -> Void)?
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
    }

    public func reportInstalling(version: String, releasePageURL: URL?) {
        phase = .updating(
            AppUpdateRelease(version: version, releasePageURL: releasePageURL)
        )
    }

    public func reportFailure(_ message: String) {
        phase = .failed(release: availableRelease, message: message)
    }

    public func reportIdle() {
        phase = .idle
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
