import Foundation
import Testing
@testable import CodevisorCore

@MainActor
@Suite("App update model")
struct AppUpdateModelTests {
  @Test("User and background checks use the correct presentation mode")
  func checkModes() async {
    let model = AppUpdateModel(currentVersion: "1.2.3", currentBuildNumber: 42)
    var modes: [Bool] = []
    model.checkHandler = { modes.append($0) }

    await model.checkForUpdatesInBackground()
    await model.checkForUpdates()

    #expect(modes == [false, true])
    #expect(model.phase == .checking)
    #expect(model.currentBuildNumber == 42)
  }

  @Test("A discovered release can be installed")
  func availableReleaseInstalls() async throws {
    let releaseURL = URL(string: "https://updates.codevisor.dev/notes/1.2.4.md")
    let model = AppUpdateModel(currentVersion: "1.2.3")
    var installed: AppUpdateRelease?
    model.installHandler = { installed = $0 }

    model.reportAvailable(version: "1.2.4", releasePageURL: releaseURL)
    let release = try #require(model.availableRelease)
    #expect(release.version == "1.2.4")
    #expect(release.releasePageURL == releaseURL)

    await model.installUpdate()
    #expect(installed == release)

    model.reportInstalling(version: release.version, releasePageURL: release.releasePageURL)
    #expect(model.phase == .updating(release))
    #expect(model.isUpdating)
  }

  @Test("Install progress is reported and cleared with the phase")
  func installProgress() {
    let model = AppUpdateModel(currentVersion: "1.2.3")
    model.reportAvailable(version: "1.2.4", releasePageURL: nil)
    model.reportInstalling(version: "1.2.4", releasePageURL: nil)
    model.reportProgress("Downloading…", fraction: 0.42)
    #expect(model.statusMessage == "Downloading…")
    #expect(model.progress == 0.42)

    // Fractions are clamped; a step without a measure clears the bar.
    model.reportProgress("Waiting for 2 chats to finish…", fraction: 1.7)
    #expect(model.progress == 1)
    model.reportProgress("Installing…")
    #expect(model.progress == nil)

    model.reportFailure("network unavailable")
    #expect(model.statusMessage == nil)
    #expect(model.progress == nil)
  }

  @Test("Failures retain the release for retry")
  func retryableFailure() {
    let model = AppUpdateModel(currentVersion: "1.2.3")
    model.reportAvailable(version: "1.2.4", releasePageURL: nil)
    model.reportFailure("network unavailable")

    #expect(
      model.phase
        == .failed(
          release: AppUpdateRelease(version: "1.2.4"),
          message: "network unavailable"
        )
    )
    #expect(model.failureMessage == "network unavailable")
    #expect(model.availableRelease?.version == "1.2.4")
  }

  @Test("Channel changes are delegated to Sparkle")
  func channelChanges() {
    let model = AppUpdateModel(currentVersion: "1.2.3")
    var values: [Bool] = []
    model.channelChangeHandler = { values.append($0) }

    model.setAllowsAlphaUpdates(true)
    model.setAllowsAlphaUpdates(false)

    #expect(values == [true, false])
    #expect(!model.allowsAlphaUpdates)
  }

  @Test("Terminal report states are explicit")
  func terminalStates() {
    let model = AppUpdateModel(currentVersion: "1.2.3")
    model.reportUpToDate()
    #expect(model.phase == .upToDate)
    model.reportIdle()
    #expect(model.phase == .idle)
  }
}
