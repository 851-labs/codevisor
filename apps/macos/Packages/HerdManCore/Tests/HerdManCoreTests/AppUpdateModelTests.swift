import Foundation
import Testing
@testable import HerdManCore

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

@MainActor
@Suite("AppUpdateModel")
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
    }
}
