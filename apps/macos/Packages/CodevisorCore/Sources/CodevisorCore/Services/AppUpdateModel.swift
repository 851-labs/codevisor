import Foundation
import Observation

/// A published release of the app, discovered by an `AppUpdateChecking`.
public struct AppUpdateRelease: Equatable, Sendable {
    /// The release tag without its leading "v" (e.g. "0.2.0" or
    /// "0.2.0-rc.123").
    public var version: String
    /// Whether GitHub marked this release as a prerelease.
    public var isPrerelease: Bool
    /// The downloadable macOS app archive (Codevisor-macOS.zip), when published.
    public var archiveURL: URL?
    /// The human-readable release page, used as a fallback when the archive
    /// can't be installed automatically.
    public var releasePageURL: URL?

    public init(
        version: String,
        isPrerelease: Bool = false,
        archiveURL: URL? = nil,
        releasePageURL: URL? = nil
    ) {
        self.version = version
        self.isPrerelease = isPrerelease
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

/// Checks the frozen compatibility manifest on the former public artifact
/// bucket. New clients use GitHub first; this remains only as a bridge for the
/// first GitHub-aware release and as an outage fallback for that release.
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

/// Checks GitHub releases and selects the app archive for the running CPU.
/// Stable mode uses `/releases/latest`; the explicitly enabled beta mode uses
/// the releases collection and admits prereleases while still rejecting drafts.
public struct GitHubAppUpdateChecker: AppUpdateChecking {
    public static let defaultAPIURL = URL(
        string: "https://api.github.com/repos/851-labs/codevisor/releases/latest"
    )!
    public static let prereleaseAPIURL = URL(
        string: "https://api.github.com/repos/851-labs/codevisor/releases?per_page=100"
    )!

    private let apiURL: URL
    private let urlSession: URLSession
    private let architecture: String
    private let includesPrereleases: Bool

    public init(
        apiURL: URL? = nil,
        urlSession: URLSession = .shared,
        architecture: String = ManifestAppUpdateChecker.currentArchitecture,
        includesPrereleases: Bool = false
    ) {
        self.apiURL = apiURL ?? (includesPrereleases ? Self.prereleaseAPIURL : Self.defaultAPIURL)
        self.urlSession = urlSession
        self.architecture = architecture
        self.includesPrereleases = includesPrereleases
    }

    public func latestRelease() async throws -> AppUpdateRelease? {
        var request = URLRequest(url: apiURL)
        request.cachePolicy = .useProtocolCachePolicy
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Codevisor-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw GitHubReleaseError.httpStatus(http.statusCode)
        }

        let releases = if includesPrereleases {
            try JSONDecoder().decode([GitHubRelease].self, from: data)
        } else {
            [try JSONDecoder().decode(GitHubRelease.self, from: data)]
        }
        guard let release = releases.first(where: {
            !$0.draft && (includesPrereleases || !$0.prerelease)
        }) else { return nil }
        let version = release.tagName.hasPrefix("v")
            ? String(release.tagName.dropFirst())
            : release.tagName
        guard !version.isEmpty else { return nil }

        let preferredName = ManifestAppUpdateChecker.archiveName(architecture: architecture)
        let archive = release.assets.first(where: { $0.name == preferredName })
            ?? release.assets.first(where: { $0.name == ManifestAppUpdateChecker.appArchiveName })
        return AppUpdateRelease(
            version: version,
            isPrerelease: release.prerelease,
            archiveURL: archive?.browserDownloadURL,
            releasePageURL: release.htmlURL
        )
    }

    private enum GitHubReleaseError: Error {
        case httpStatus(Int)
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            var name: String
            var browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        var tagName: String
        var htmlURL: URL
        var draft: Bool
        var prerelease: Bool
        var assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
            case prerelease
            case assets
        }
    }
}

/// Uses the compatibility source only when GitHub is unavailable. A valid
/// GitHub response (including no published release) remains authoritative.
public struct FallbackAppUpdateChecker: AppUpdateChecking {
    private let primary: any AppUpdateChecking
    private let fallback: any AppUpdateChecking

    public init(primary: any AppUpdateChecking, fallback: any AppUpdateChecking) {
        self.primary = primary
        self.fallback = fallback
    }

    public func latestRelease() async throws -> AppUpdateRelease? {
        do {
            return try await primary.latestRelease()
        } catch {
            return try await fallback.latestRelease()
        }
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
    public let currentReleaseChannel: String
    public let currentBuildNumber: Int?
    public private(set) var allowsPrereleaseUpdates: Bool

    /// Downloads and installs a release, then relaunches the app. On success
    /// it never returns (the process is replaced).
    public var installHandler: (@MainActor (AppUpdateRelease) async throws -> Void)?

    private let checker: any AppUpdateChecking
    private let prereleaseChecker: (any AppUpdateChecking)?

    public init(
        currentVersion: String,
        currentReleaseChannel: String = "stable",
        currentBuildNumber: Int? = nil,
        checker: any AppUpdateChecking,
        prereleaseChecker: (any AppUpdateChecking)? = nil,
        allowsPrereleaseUpdates: Bool = false
    ) {
        self.currentVersion = currentVersion
        self.currentReleaseChannel = currentReleaseChannel
        self.currentBuildNumber = currentBuildNumber
        self.checker = checker
        self.prereleaseChecker = prereleaseChecker
        self.allowsPrereleaseUpdates = allowsPrereleaseUpdates
    }

    public func setAllowsPrereleaseUpdates(_ value: Bool) {
        allowsPrereleaseUpdates = value
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
            let selectedChecker = allowsPrereleaseUpdates ? (prereleaseChecker ?? checker) : checker
            guard let release = try await selectedChecker.latestRelease(),
                  Self.shouldOfferRelease(
                    release.version,
                    candidateIsPrerelease: release.isPrerelease,
                    currentVersion: currentVersion,
                    currentReleaseChannel: currentReleaseChannel,
                    currentBuildNumber: currentBuildNumber
                  ) else {
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

    /// A stable build replaces an RC with the same marketing version. This is
    /// needed because RC artifacts are signed/notarized with the next stable
    /// version, while their channel marker distinguishes them from the release.
    public static func shouldOfferStableRelease(
        _ candidate: String,
        currentVersion: String,
        currentReleaseChannel: String
    ) -> Bool {
        shouldOfferRelease(
            candidate,
            candidateIsPrerelease: false,
            currentVersion: currentVersion,
            currentReleaseChannel: currentReleaseChannel,
            currentBuildNumber: nil
        )
    }

    /// Orders stable and prerelease builds. Marketing versions remain the
    /// primary key; within one marketing version, a stable build supersedes
    /// every RC and RC workflow run numbers order beta-to-beta updates.
    public static func shouldOfferRelease(
        _ candidate: String,
        candidateIsPrerelease: Bool,
        currentVersion: String,
        currentReleaseChannel: String,
        currentBuildNumber: Int?
    ) -> Bool {
        let candidateComponents = numericComponents(candidate)
        let currentComponents = numericComponents(currentVersion)
        if compare(candidateComponents, currentComponents) > 0 { return true }
        if compare(candidateComponents, currentComponents) < 0 { return false }
        if !candidateIsPrerelease { return currentReleaseChannel == "rc" }
        guard currentReleaseChannel == "rc",
              let candidateBuild = rcBuildNumber(candidate),
              let currentBuildNumber else { return false }
        return candidateBuild > currentBuildNumber
    }

    /// The running app's marketing version (stamped by the release build).
    public static func bundleVersion(_ bundle: Bundle = .main) -> String {
        (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    public static func bundleReleaseChannel(_ bundle: Bundle = .main) -> String {
        (bundle.object(forInfoDictionaryKey: "CodevisorReleaseChannel") as? String) ?? "stable"
    }

    public static func bundleBuildNumber(_ bundle: Bundle = .main) -> Int? {
        guard let value = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            return nil
        }
        return Int(value)
    }

    private static func compare(_ lhs: [Int], _ rhs: [Int]) -> Int {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }

    private static func rcBuildNumber(_ version: String) -> Int? {
        let normalized = version.lowercased()
        guard let range = normalized.range(of: "-rc.", options: .backwards) else { return nil }
        return Int(normalized[range.upperBound...])
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
