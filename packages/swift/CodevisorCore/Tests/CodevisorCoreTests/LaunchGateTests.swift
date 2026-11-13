import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

@Suite("Launch screen")
struct LaunchGateTests {
  private let upgrading = LocalDataUpgradeProgress(
    state: "running", id: "incremental-vacuum-v1", name: "Freeing up disk space", completed: 0, total: 1
  )

  private func opened() -> LaunchGate {
    var gate = LaunchGate()
    gate.note(gate.phase(for: LaunchSnapshot(hasLocalData: true, availability: .ready)))
    return gate
  }

  @Test("Shows the icon until this Mac's server answers, then gets out of the way")
  func waitsForTheServer() {
    let gate = LaunchGate()

    #expect(gate.phase(for: LaunchSnapshot(hasLocalData: false)) == .starting)
    #expect(gate.phase(for: LaunchSnapshot(hasLocalData: true, availability: .waiting(.starting))) == .starting)
    #expect(gate.phase(for: LaunchSnapshot(hasLocalData: true, availability: .ready)) == .ready)
  }

  @Test("Stays out of the way when the server reconnects after the app opened")
  func ignoresLaterReconnects() {
    let gate = opened()

    #expect(gate.phase(for: LaunchSnapshot(hasLocalData: true, availability: .waiting(.restarting))) == .ready)
  }

  @Test("Shows a data update at launch and when the server restarts into one later")
  func showsDataUpdates() {
    let snapshot = LaunchSnapshot(hasLocalData: true, dataUpgrade: upgrading, availability: .waiting(.starting))

    #expect(LaunchGate().phase(for: snapshot) == .updatingData(upgrading))
    #expect(opened().phase(for: snapshot) == .updatingData(upgrading))
  }

  @Test("Shows a failed start, and opens without this Mac when asked")
  func continuesPastAFailedStart() {
    var gate = LaunchGate()
    let snapshot = LaunchSnapshot(hasLocalData: true, serverState: .unavailable("Port in use"))
    let failure = LaunchFailure(stage: .server, message: "Port in use")
    #expect(gate.phase(for: snapshot) == .failed(failure))

    gate.continueAnyway(past: failure)

    #expect(gate.phase(for: snapshot) == .ready)
  }

  @Test("Can't continue past local data that failed to open")
  func blocksOnLocalData() {
    var gate = LaunchGate()
    let failure = LaunchFailure(stage: .localData, message: "Disk full")

    gate.continueAnyway(past: failure)

    #expect(gate.phase(for: LaunchSnapshot(localDataFailure: "Disk full", hasLocalData: false)) == .failed(failure))
  }

  @Test("Shows a failed data update until dismissed, and shows a different one again")
  func showsNewUpgradeFailures() {
    var gate = opened()
    var failed = upgrading
    failed.state = "failed"
    failed.error = "disk I/O error"
    let snapshot = LaunchSnapshot(hasLocalData: true, dataUpgrade: failed)
    let failure = LaunchFailure(stage: .dataUpgrade, message: "disk I/O error")
    #expect(gate.phase(for: snapshot) == .failed(failure))

    gate.continueAnyway(past: failure)
    #expect(gate.phase(for: snapshot) == .ready)

    failed.error = "database is locked"
    #expect(gate.phase(for: LaunchSnapshot(hasLocalData: true, dataUpgrade: failed)) != .ready)
  }

  @Test("Says a slow start is taking a while, except while Git is installing")
  func notesASlowStart() {
    let gate = LaunchGate()
    let slow = LaunchSnapshot(hasLocalData: true, availability: .waiting(.starting), startIsSlow: true)
    var installingGit = slow
    installingGit.isWaitingForGit = true

    #expect(gate.phase(for: slow) == .startingSlowly)
    #expect(gate.phase(for: installingGit) == .starting)
  }
}

@Suite("Launch data upgrade steps")
struct LaunchUpgradeLogTests {
  private func progress(_ id: String, _ completed: Int, of total: Int) -> LocalDataUpgradeProgress {
    LocalDataUpgradeProgress(state: "running", id: id, name: id, completed: completed, total: total)
  }

  @Test("Lists each upgrade as it starts and checks off the ones before it")
  func listsUpgradesInOrder() {
    var log = LaunchUpgradeLog()
    log.note(progress("Linking attachments", 2, of: 6))
    log.note(progress("Linking attachments", 5, of: 6))
    log.note(nil)

    let shown = log.including(progress("Freeing up disk space", 0, of: 1)).entries

    #expect(shown.map(\.name) == ["Linking attachments", "Freeing up disk space"])
    #expect(shown.map(\.isFinished) == [true, false])
    #expect(shown.first?.completed == 6)
  }

  @Test("Starts over for an upgrade that comes after the app opened")
  func startsOver() {
    var log = LaunchUpgradeLog()
    log.note(progress("Linking attachments", 6, of: 6))

    log.clear()

    #expect(log.including(progress("Freeing up disk space", 0, of: 1)).entries.map(\.name) == ["Freeing up disk space"])
  }
}

@Suite("Launch issue report")
struct LaunchIssueReportTests {
  @Test("Prefills a GitHub issue, shortening a long error to fit the link")
  func prefillsAnIssue() throws {
    let error = String(repeating: "x", count: 4_000)
    let report = LaunchIssueReport(
      failure: LaunchFailure(stage: .server, message: error),
      appVersion: "0.1.120",
      systemVersion: "Version 27.2"
    )

    let query = try #require(URLComponents(url: report.url, resolvingAgainstBaseURL: false)?.queryItems)
    let body = try #require(query.first { $0.name == "body" }?.value)
    #expect(report.url.absoluteString.hasPrefix("https://github.com/851-labs/codevisor/issues/new?"))
    #expect(query.first { $0.name == "title" }?.value == "Codevisor Couldn't Start")
    #expect(body.contains("Codevisor 0.1.120"))
    #expect(body.contains("… (shortened)"))
    #expect(!body.contains(error))
  }
}
