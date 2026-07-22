import Foundation
import Testing
@testable import CodevisorCore

private struct FakeUpdateChecker: AppUpdateChecking {
    var release: AppUpdateRelease?
    var error: Error?

    func latestRelease() async throws -> AppUpdateRelease? {
        if let error { throw error }
        return release
    }
}

private struct UpdateTestError: LocalizedError {
    var errorDescription: String? { "download failed" }
}

private final class MutableUpdateChecker: AppUpdateChecking, @unchecked Sendable {
    var release: AppUpdateRelease?
    var error: Error?

    init(release: AppUpdateRelease? = nil, error: Error? = nil) {
        self.release = release
        self.error = error
    }

    func latestRelease() async throws -> AppUpdateRelease? {
        if let error { throw error }
        return release
    }
}

/// Serves canned HTTP responses to the manifest checker's URLSession.
private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (status: Int, body: Data))?

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: UpdateTestError())
            return
        }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// Serialized: the manifest checker tests share StubURLProtocol's static handler.
@MainActor
@Suite("AppUpdateModel", .serialized)
struct AppUpdateModelTests {
    @Test("A newer release becomes available")
    func newerReleaseAvailable() async {
        let release = AppUpdateRelease(version: "0.2.0", archiveURL: URL(string: "https://example.com/app.zip"))
        let model = AppUpdateModel(currentVersion: "0.1.7", checker: FakeUpdateChecker(release: release))

        await model.checkForUpdates()

        #expect(model.phase == .available(release))
        #expect(model.availableRelease == release)
    }

    @Test("Same or older releases report up to date")
    func olderReleaseUpToDate() async {
        let model = AppUpdateModel(
            currentVersion: "0.2.0",
            checker: FakeUpdateChecker(release: AppUpdateRelease(version: "0.2.0"))
        )

        await model.checkForUpdates()

        #expect(model.phase == .upToDate)
        #expect(model.availableRelease == nil)
    }

    @Test("Stable release replaces an RC with the same marketing version")
    func stableReleaseReplacesSameVersionRC() async {
        let release = AppUpdateRelease(version: "0.2.0")
        let model = AppUpdateModel(
            currentVersion: "0.2.0",
            currentReleaseChannel: "rc",
            checker: FakeUpdateChecker(release: release)
        )

        await model.checkForUpdates()

        #expect(model.phase == .available(release))
    }

    @Test("A newer RC build replaces an older RC of the same marketing version")
    func newerRCBuildAvailable() async {
        let release = AppUpdateRelease(version: "0.2.0-rc.43", isPrerelease: true)
        let model = AppUpdateModel(
            currentVersion: "0.2.0",
            currentReleaseChannel: "rc",
            currentBuildNumber: 42,
            checker: FakeUpdateChecker(),
            prereleaseChecker: FakeUpdateChecker(release: release),
            allowsPrereleaseUpdates: true
        )

        await model.checkForUpdates()

        #expect(model.phase == .available(release))
    }

    @Test("Stable update mode never consults the prerelease checker")
    func stableModeIgnoresPrereleases() async {
        let prerelease = AppUpdateRelease(version: "0.2.0-rc.43", isPrerelease: true)
        let model = AppUpdateModel(
            currentVersion: "0.1.0",
            checker: FakeUpdateChecker(),
            prereleaseChecker: FakeUpdateChecker(release: prerelease)
        )

        await model.checkForUpdates()
        #expect(model.phase == .upToDate)

        model.setAllowsPrereleaseUpdates(true)
        await model.checkForUpdates()
        #expect(model.phase == .available(prerelease))
    }

    @Test("Check failures stay silent")
    func checkFailureIsSilent() async {
        let model = AppUpdateModel(
            currentVersion: "0.1.0",
            checker: FakeUpdateChecker(error: UpdateTestError())
        )

        await model.checkForUpdates()

        #expect(model.phase == .idle)
        #expect(model.availableRelease == nil)
    }

    @Test("Background checks can surface a newer release")
    func backgroundCheckFindsNewerRelease() async {
        let release = AppUpdateRelease(version: "0.2.0")
        let model = AppUpdateModel(
            currentVersion: "0.1.0",
            checker: FakeUpdateChecker(release: release)
        )

        await model.checkForUpdatesInBackground()

        #expect(model.phase == .available(release))
        #expect(model.availableRelease == release)
    }

    @Test("Background check failures keep the current update banner")
    func backgroundCheckFailureKeepsAvailableRelease() async {
        let release = AppUpdateRelease(version: "0.2.0")
        let checker = MutableUpdateChecker(release: release)
        let model = AppUpdateModel(currentVersion: "0.1.0", checker: checker)

        await model.checkForUpdates()
        checker.release = nil
        checker.error = UpdateTestError()
        await model.checkForUpdatesInBackground()

        #expect(model.phase == .available(release))
        #expect(model.availableRelease == release)
    }

    @Test("Background checks keep retry state for the same failed release")
    func backgroundCheckKeepsFailedReleaseRetryState() async {
        let release = AppUpdateRelease(version: "0.2.0")
        let checker = MutableUpdateChecker(release: release)
        let model = AppUpdateModel(currentVersion: "0.1.0", checker: checker)
        model.installHandler = { _ in throw UpdateTestError() }

        await model.checkForUpdates()
        await model.installUpdate()
        await model.checkForUpdatesInBackground()

        #expect(model.phase == .failed(release: release, message: "download failed"))
        #expect(model.failureMessage == "download failed")
    }

    @Test("Install failure keeps the release available for retry")
    func installFailureIsRetryable() async {
        let release = AppUpdateRelease(version: "0.2.0")
        let model = AppUpdateModel(currentVersion: "0.1.0", checker: FakeUpdateChecker(release: release))
        model.installHandler = { _ in throw UpdateTestError() }

        await model.checkForUpdates()
        await model.installUpdate()

        #expect(model.phase == .failed(release: release, message: "download failed"))
        #expect(model.failureMessage == "download failed")
        #expect(model.availableRelease == release)
        #expect(model.isUpdating == false)
    }

    @Test("Install runs the injected handler and stays in updating on success")
    func installRunsHandler() async {
        let release = AppUpdateRelease(version: "0.2.0")
        let model = AppUpdateModel(currentVersion: "0.1.0", checker: FakeUpdateChecker(release: release))
        var installed: AppUpdateRelease?
        model.installHandler = { installed = $0 }

        await model.checkForUpdates()
        await model.installUpdate()

        #expect(installed == release)
        #expect(model.phase == .updating(release))
        #expect(model.isUpdating)
    }

    @Test("Manifest checker prefers the architecture-specific archive when published")
    func manifestCheckerPrefersArchitectureArchive() async throws {
        let base = URL(string: "https://releases.example.com/codevisor")!
        var requestedURLs: [URL] = []
        StubURLProtocol.handler = { request in
            if let url = request.url { requestedURLs.append(url) }
            if request.httpMethod == "HEAD" {
                return (200, Data())
            }
            return (200, Data(#"{"version":"0.3.0"}"#.utf8))
        }
        defer { StubURLProtocol.handler = nil }
        let checker = ManifestAppUpdateChecker(
            baseURL: base,
            urlSession: StubURLProtocol.makeSession(),
            architecture: "arm64"
        )

        let release = try await checker.latestRelease()

        #expect(requestedURLs == [
            URL(string: "https://releases.example.com/codevisor/latest.json")!,
            URL(string: "https://releases.example.com/codevisor/v0.3.0/Codevisor-macOS-arm64.zip")!
        ])
        #expect(release?.version == "0.3.0")
        #expect(
            release?.archiveURL
                == URL(string: "https://releases.example.com/codevisor/v0.3.0/Codevisor-macOS-arm64.zip")
        )
        #expect(release?.releasePageURL == nil)
    }

    @Test("Manifest checker falls back to the universal archive for pre-split releases")
    func manifestCheckerFallsBackToUniversalArchive() async throws {
        let base = URL(string: "https://releases.example.com/codevisor")!
        StubURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" {
                return (404, Data())
            }
            return (200, Data(#"{"version":"0.3.0"}"#.utf8))
        }
        defer { StubURLProtocol.handler = nil }
        let checker = ManifestAppUpdateChecker(
            baseURL: base,
            urlSession: StubURLProtocol.makeSession(),
            architecture: "x64"
        )

        let release = try await checker.latestRelease()

        #expect(release?.version == "0.3.0")
        #expect(
            release?.archiveURL
                == URL(string: "https://releases.example.com/codevisor/v0.3.0/Codevisor-macOS.zip")
        )
    }

    @Test("Architecture archive names follow the release artifact convention")
    func architectureArchiveNames() {
        #expect(ManifestAppUpdateChecker.archiveName(architecture: "arm64") == "Codevisor-macOS-arm64.zip")
        #expect(ManifestAppUpdateChecker.archiveName(architecture: "x64") == "Codevisor-macOS-x64.zip")
        #expect(["arm64", "x64"].contains(ManifestAppUpdateChecker.currentArchitecture))
    }

    @Test("Manifest checker reports no release when the manifest is missing")
    func manifestCheckerHandlesMissingManifest() async throws {
        StubURLProtocol.handler = { _ in (404, Data()) }
        defer { StubURLProtocol.handler = nil }
        let checker = ManifestAppUpdateChecker(
            baseURL: URL(string: "https://releases.example.com/codevisor")!,
            urlSession: StubURLProtocol.makeSession()
        )

        let release = try await checker.latestRelease()

        #expect(release == nil)
    }

    @Test("GitHub checker selects the current architecture from the latest stable release")
    func githubCheckerSelectsArchitectureArchive() async throws {
        var capturedRequest: URLRequest?
        StubURLProtocol.handler = { request in
            capturedRequest = request
            return (200, Data(#"""
            {
                "tag_name":"v0.4.0",
                "html_url":"https://github.com/851-labs/codevisor/releases/tag/v0.4.0",
                "draft":false,
                "prerelease":false,
                "assets":[
                    {"name":"Codevisor-macOS-x64.zip","browser_download_url":"https://github.example/x64.zip"},
                    {"name":"Codevisor-macOS-arm64.zip","browser_download_url":"https://github.example/arm64.zip"}
                ]
            }
            """#.utf8))
        }
        defer { StubURLProtocol.handler = nil }
        let checker = GitHubAppUpdateChecker(
            apiURL: URL(string: "https://api.github.example/releases/latest")!,
            urlSession: StubURLProtocol.makeSession(),
            architecture: "x64"
        )

        let release = try await checker.latestRelease()

        #expect(release == AppUpdateRelease(
            version: "0.4.0",
            archiveURL: URL(string: "https://github.example/x64.zip"),
            releasePageURL: URL(string: "https://github.com/851-labs/codevisor/releases/tag/v0.4.0")
        ))
        #expect(capturedRequest?.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(capturedRequest?.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    }

    @Test("GitHub checker falls back to the universal asset")
    func githubCheckerFallsBackToUniversalArchive() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"""
            {
                "tag_name":"0.3.0",
                "html_url":"https://github.example/release",
                "draft":false,
                "prerelease":false,
                "assets":[
                    {"name":"Codevisor-macOS.zip","browser_download_url":"https://github.example/universal.zip"}
                ]
            }
            """#.utf8))
        }
        defer { StubURLProtocol.handler = nil }
        let checker = GitHubAppUpdateChecker(
            apiURL: URL(string: "https://api.github.example/releases/latest")!,
            urlSession: StubURLProtocol.makeSession(),
            architecture: "arm64"
        )

        let release = try await checker.latestRelease()

        #expect(release?.archiveURL == URL(string: "https://github.example/universal.zip"))
    }

    @Test("GitHub beta checker includes prereleases but excludes drafts")
    func githubBetaCheckerIncludesPrereleases() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"""
            [
                {
                    "tag_name":"v0.5.0-rc.43",
                    "html_url":"https://github.example/rc",
                    "draft":true,
                    "prerelease":true,
                    "assets":[]
                },
                {
                    "tag_name":"v0.5.0-rc.42",
                    "html_url":"https://github.example/rc",
                    "draft":false,
                    "prerelease":true,
                    "assets":[
                        {"name":"Codevisor-macOS-arm64.zip","browser_download_url":"https://github.example/rc.zip"}
                    ]
                },
                {
                    "tag_name":"v0.4.0",
                    "html_url":"https://github.example/stable",
                    "draft":false,
                    "prerelease":false,
                    "assets":[]
                }
            ]
            """#.utf8))
        }
        defer { StubURLProtocol.handler = nil }
        let checker = GitHubAppUpdateChecker(
            apiURL: URL(string: "https://api.github.example/releases?per_page=100")!,
            urlSession: StubURLProtocol.makeSession(),
            architecture: "arm64",
            includesPrereleases: true
        )

        let release = try await checker.latestRelease()

        #expect(release == AppUpdateRelease(
            version: "0.5.0-rc.42",
            isPrerelease: true,
            archiveURL: URL(string: "https://github.example/rc.zip"),
            releasePageURL: URL(string: "https://github.example/rc")
        ))
    }

    @Test("GitHub stable checker rejects a prerelease response defensively")
    func githubStableCheckerRejectsPrerelease() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"""
            {
                "tag_name":"v0.5.0-rc.42",
                "html_url":"https://github.example/rc",
                "draft":false,
                "prerelease":true,
                "assets":[]
            }
            """#.utf8))
        }
        defer { StubURLProtocol.handler = nil }
        let checker = GitHubAppUpdateChecker(
            apiURL: URL(string: "https://api.github.example/releases/latest")!,
            urlSession: StubURLProtocol.makeSession()
        )

        #expect(try await checker.latestRelease() == nil)
    }

    @Test("Compatibility checker is used when GitHub is unavailable")
    func updateCheckerFallsBackWhenGitHubFails() async throws {
        let expected = AppUpdateRelease(version: "0.3.0")
        let checker = FallbackAppUpdateChecker(
            primary: FakeUpdateChecker(error: UpdateTestError()),
            fallback: FakeUpdateChecker(release: expected)
        )

        #expect(try await checker.latestRelease() == expected)
    }

    @Test("Version comparison handles v-prefixes, lengths, and prereleases")
    func versionComparison() {
        #expect(AppUpdateModel.isVersion("0.2.0", newerThan: "0.1.9"))
        #expect(AppUpdateModel.isVersion("v0.2.0", newerThan: "0.1.9"))
        #expect(AppUpdateModel.isVersion("1.0", newerThan: "0.9.9"))
        #expect(AppUpdateModel.isVersion("0.1.10", newerThan: "0.1.9"))
        #expect(AppUpdateModel.isVersion("0.1.7.1", newerThan: "0.1.7"))
        #expect(AppUpdateModel.isVersion("0.2.0-beta.1", newerThan: "0.1.9"))
        #expect(!AppUpdateModel.isVersion("0.1.9", newerThan: "0.1.9"))
        #expect(!AppUpdateModel.isVersion("0.1.8", newerThan: "0.1.9"))
        #expect(!AppUpdateModel.isVersion("v0.1.9", newerThan: "0.1.9"))
        #expect(AppUpdateModel.shouldOfferStableRelease(
            "0.1.9",
            currentVersion: "0.1.9",
            currentReleaseChannel: "rc"
        ))
        #expect(!AppUpdateModel.shouldOfferStableRelease(
            "0.1.9",
            currentVersion: "0.1.9",
            currentReleaseChannel: "stable"
        ))
        #expect(AppUpdateModel.shouldOfferRelease(
            "0.2.0-rc.43",
            candidateIsPrerelease: true,
            currentVersion: "0.2.0",
            currentReleaseChannel: "rc",
            currentBuildNumber: 42
        ))
        #expect(!AppUpdateModel.shouldOfferRelease(
            "0.2.0-rc.42",
            candidateIsPrerelease: true,
            currentVersion: "0.2.0",
            currentReleaseChannel: "rc",
            currentBuildNumber: 42
        ))
        #expect(!AppUpdateModel.shouldOfferRelease(
            "0.2.0-rc.44",
            candidateIsPrerelease: true,
            currentVersion: "0.2.0",
            currentReleaseChannel: "stable",
            currentBuildNumber: 43
        ))
    }
}
