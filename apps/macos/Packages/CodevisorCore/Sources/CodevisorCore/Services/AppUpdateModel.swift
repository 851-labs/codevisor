import Foundation
import Observation

/// A published release of the app, discovered by an `AppUpdateChecking`.
public struct AppUpdateRelease: Equatable, Sendable {
    /// The release's version, without any leading "v" (e.g. "0.2.0").
    public var version: String
    /// The downloadable macOS app archive (Codevisor-macOS.zip), when published.
    public var archiveURL: URL?
    /// The human-readable release page, used as a fallback when the archive
    /// can't be installed automatically.
    public var releasePageURL: URL?

    public init(version: String, archiveURL: URL? = nil, releasePageURL: URL? = nil) {
        self.version = version
        self.archiveURL = archiveURL
        self.releasePageURL = releasePageURL
    }
}

/// Discovers the newest published release of the app.
public protocol AppUpdateChecking: Sendable {
    /// The newest published release, or nil when none could be determined.
    func latestRelease() async throws -> AppUpdateRelease?
}

/// A checker that never reports an update (previews and tests).
public struct DisabledUpdateChecker: AppUpdateChecking {
    public init() {}
    public func latestRelease() async throws -> AppUpdateRelease? { nil }
}

/// Checks the release manifest on the public artifact bucket that distributes
/// the app (the same bucket the Homebrew cask installs from). The source
/// repository is private, so the GitHub releases API is unreachable from user
/// machines; the bucket is the one public source of release truth.
public struct ManifestAppUpdateChecker: AppUpdateChecking {
    /// The universal macOS app archive, shipped by every release before the
    /// architecture split and kept as a transitional artifact afterwards so
    /// pre-split apps can still update.
    public static let appArchiveName = "Codevisor-macOS.zip"

    /// The running app's CPU architecture in release-artifact naming.
    public static var currentArchitecture: String {
        #if arch(x86_64)
            "x64"
        #else
            "arm64"
        #endif
    }

    /// The architecture-specific app archive published by split releases.
    /// Half the download and installed size of the universal archive.
    public static func archiveName(architecture: String) -> String {
        "Codevisor-macOS-\(architecture).zip"
    }

    private let baseURL: URL
    private let urlSession: URLSession
    private let architecture: String

    /// - Parameter baseURL: the release prefix that contains `latest.json`
    ///   and the `v<version>/` artifact directories.
    public init(
        baseURL: URL,
        urlSession: URLSession = .shared,
        architecture: String = Self.currentArchitecture
    ) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.architecture = architecture
    }

    public func latestRelease() async throws -> AppUpdateRelease? {
        // Skip local caches: the manifest is tiny and must reflect the
        // current release, not the one cached at the previous check.
        var request = URLRequest(url: baseURL.appendingPathComponent("latest.json"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        let manifest = try JSONDecoder().decode(ReleaseManifest.self, from: data)
        let version = manifest.version.hasPrefix("v") ? String(manifest.version.dropFirst()) : manifest.version
        guard !version.isEmpty else { return nil }
        let versionDirectory = baseURL.appendingPathComponent("v\(version)")
        return AppUpdateRelease(
            version: version,
            archiveURL: await archiveURL(in: versionDirectory)
        )
    }

    /// Prefers the architecture-specific archive when the release publishes
    /// one, falling back to the universal archive for releases from before
    /// the split. Probe failures (offline mid-check) fall back too; the
    /// universal archive remains correct on both architectures.
    private func archiveURL(in versionDirectory: URL) async -> URL {
        let candidate = versionDirectory
            .appendingPathComponent(Self.archiveName(architecture: architecture))
        var request = URLRequest(url: candidate)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let (_, response) = try? await urlSession.data(for: request),
           let http = response as? HTTPURLResponse,
           (200..<300).contains(http.statusCode) {
            return candidate
        }
        return versionDirectory.appendingPathComponent(Self.appArchiveName)
    }

    private struct ReleaseManifest: Decodable {
        var version: String
    }
}

/// Tracks whether a newer version of the app is available and runs the install
/// flow. The download/swap/relaunch work is injected by the app target via
/// `installHandler` so this model stays AppKit-free and unit-testable.
@MainActor
@Observable
public final class AppUpdateModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case checking
        case upToDate
        case available(AppUpdateRelease)
        case updating(AppUpdateRelease)
        case failed(release: AppUpdateRelease, message: String)
    }

    public private(set) var phase: Phase = .idle
    public let currentVersion: String

    /// Downloads and installs a release, then relaunches the app. On success
    /// it never returns (the process is replaced).
    public var installHandler: (@MainActor (AppUpdateRelease) async throws -> Void)?

    private let checker: any AppUpdateChecking

    public init(currentVersion: String, checker: any AppUpdateChecking) {
        self.currentVersion = currentVersion
        self.checker = checker
    }

    /// The release behind the banner, regardless of install progress.
    public var availableRelease: AppUpdateRelease? {
        switch phase {
        case let .available(release), let .updating(release), let .failed(release, _):
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

    /// Fetches the latest release and records whether it is newer than the
    /// running app. Check failures (offline, rate limits) are silent: the
    /// banner simply doesn't appear.
    public func checkForUpdates() async {
        await checkForUpdates(showsCheckingPhase: true)
    }

    /// Refreshes update availability without temporarily hiding an existing
    /// update banner. Intended for scheduled background checks.
    public func checkForUpdatesInBackground() async {
        await checkForUpdates(showsCheckingPhase: false)
    }

    private func checkForUpdates(showsCheckingPhase: Bool) async {
        if case .updating = phase { return }
        if case .checking = phase { return }
        if showsCheckingPhase {
            phase = .checking
        }
        do {
            guard let release = try await checker.latestRelease(),
                  Self.isVersion(release.version, newerThan: currentVersion) else {
                phase = .upToDate
                return
            }
            if !showsCheckingPhase,
               case let .failed(existingRelease, message) = phase,
               existingRelease.version == release.version {
                phase = .failed(release: release, message: message)
                return
            }
            phase = .available(release)
        } catch {
            // Routine when offline or rate-limited; the banner simply
            // doesn't appear.
            Log.updates.debug(
                "Update check failed: \(String(describing: error), privacy: .public)"
            )
            if showsCheckingPhase {
                phase = .idle
            }
        }
    }

    /// Runs the injected installer for the available release. On failure the
    /// release stays available so the user can retry.
    public func installUpdate() async {
        guard let release = availableRelease, let installHandler else { return }
        phase = .updating(release)
        do {
            try await installHandler(release)
        } catch {
            phase = .failed(release: release, message: error.localizedDescription)
        }
    }

    /// Compares dotted numeric versions: "0.2.0" is newer than "0.1.9".
    /// A leading "v" and any prerelease suffix ("-beta.1") are ignored.
    public static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let lhs = numericComponents(candidate)
        let rhs = numericComponents(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// The running app's marketing version (stamped by the release build).
    public static func bundleVersion(_ bundle: Bundle = .main) -> String {
        (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    private static func numericComponents(_ version: String) -> [Int] {
        var normalized = version.trimmingCharacters(in: .whitespaces)
        if normalized.hasPrefix("v") || normalized.hasPrefix("V") {
            normalized = String(normalized.dropFirst())
        }
        let base = normalized.split(separator: "-").first.map(String.init) ?? normalized
        return base.split(separator: ".").map { Int($0) ?? 0 }
    }
}
