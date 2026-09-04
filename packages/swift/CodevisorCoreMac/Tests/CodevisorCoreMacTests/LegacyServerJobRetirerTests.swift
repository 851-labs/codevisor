import Foundation
import Testing
@testable import CodevisorCoreMac

@Suite("LegacyServerJobRetirer")
struct LegacyServerJobRetirerTests {
  @Test("Boots out every updater-era launchd job")
  func removesEveryLegacyJob() async throws {
    let runner = RecordingLaunchctlRunner(result: .success)
    let retirer = LegacyServerJobRetirer(runner: runner, userID: 501)

    try await retirer.retire()

    let invocations = await runner.invocations
    #expect(invocations.count == LegacyServerJobRetirer.labels.count)
    for label in LegacyServerJobRetirer.labels {
      #expect(invocations.contains(["bootout", "gui/501/\(label)"]))
    }
  }

  @Test("Treats an already-absent job as retired")
  func acceptsMissingJobs() async throws {
    let runner = RecordingLaunchctlRunner(result: .missing)
    let retirer = LegacyServerJobRetirer(runner: runner, userID: 501)

    try await retirer.retire()

    #expect(await runner.invocations.count == LegacyServerJobRetirer.labels.count)
  }

  @Test("Surfaces real bootout failures")
  func reportsBootoutFailure() async {
    let runner = RecordingLaunchctlRunner(result: .failure)
    let retirer = LegacyServerJobRetirer(runner: runner, userID: 501)

    await #expect(throws: LegacyServerJobRetirementError.self) {
      try await retirer.retire()
    }
  }

  @Test("Times out a cleanup command instead of pinning startup")
  func timesOutHangingCleanup() async {
    let retirer = LegacyServerJobRetirer(
      runner: HangingLaunchctlRunner(),
      userID: 501,
      commandTimeout: .milliseconds(25)
    )

    await #expect(throws: CommandRunnerError.self) {
      try await retirer.retire()
    }
  }
}

private actor RecordingLaunchctlRunner: CommandRunner {
  enum Result {
    case success
    case missing
    case failure
  }

  let result: Result
  private(set) var invocations: [[String]] = []

  init(result: Result) {
    self.result = result
  }

  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String]?
  ) async throws -> CommandResult {
    invocations.append(arguments)
    switch result {
    case .success:
      return CommandResult(standardOutput: "", standardError: "", exitCode: 0)
    case .missing:
      return CommandResult(
        standardOutput: "",
        standardError: "Boot-out failed: 3: No such process",
        exitCode: 3
      )
    case .failure:
      return CommandResult(
        standardOutput: "",
        standardError: "Boot-out failed: 1: Operation not permitted",
        exitCode: 1
      )
    }
  }
}

private actor HangingLaunchctlRunner: CommandRunner {
  func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String]?
  ) async throws -> CommandResult {
    try await Task.sleep(for: .seconds(5))
    return CommandResult(standardOutput: "", standardError: "", exitCode: 0)
  }
}

@Suite("ProcessCommandRunner")
struct ProcessCommandRunnerTests {
  @Test("Terminates a child process when its deadline expires")
  func terminatesTimedOutProcess() async {
    let runner = ProcessCommandRunner()

    await #expect(throws: CommandRunnerError.self) {
      try await runner.run(
        executableURL: URL(fileURLWithPath: "/bin/sleep"),
        arguments: ["5"],
        environment: nil,
        timeout: .milliseconds(25)
      )
    }
  }
}

@Suite("LaunchctlPrintOutput")
struct LaunchctlPrintOutputTests {
  @Test("Only confirmed missing or stopped jobs count as stopped")
  func classifiesJobState() {
    #expect(
      LaunchctlPrintOutput.isRunning(CommandResult(standardOutput: "pid = 123", standardError: "", exitCode: 0)) == true
    )
    #expect(
      LaunchctlPrintOutput.isRunning(
        CommandResult(standardOutput: "state = not running", standardError: "", exitCode: 0)) == false)
    #expect(
      LaunchctlPrintOutput.isRunning(CommandResult(standardOutput: "state = waiting", standardError: "", exitCode: 0))
        == false)
    #expect(
      LaunchctlPrintOutput.isRunning(CommandResult(standardOutput: "", standardError: "missing", exitCode: 113))
        == false)
    #expect(
      LaunchctlPrintOutput.isRunning(CommandResult(standardOutput: "", standardError: "missing", exitCode: 3)) == false)
    #expect(
      LaunchctlPrintOutput.isRunning(CommandResult(standardOutput: "", standardError: "permission denied", exitCode: 5))
        == nil)
    #expect(
      LaunchctlPrintOutput.isRunning(CommandResult(standardOutput: "unreadable", standardError: "", exitCode: 0)) == nil
    )
  }

  @Test("Finds the job's live pid")
  func findsPid() {
    let output = """
      gui/501/com.851labs.Codevisor.ServerAgent = {
      \tactive count = 1
      \tpath = /Users/me/Library/LaunchAgents/com.851labs.Codevisor.ServerAgent.plist
      \tstate = running
      \tpid = 70634
      \tprogram = /bin/bash
      }
      """
    #expect(LaunchctlPrintOutput.pid(in: output) == 70634)
  }

  @Test("A job without a process has no pid")
  func noPid() {
    let output = """
      gui/501/com.851labs.Codevisor.ServerAgent = {
      \tactive count = 0
      \tstate = not running
      \tlast exit code = 78
      }
      """
    #expect(LaunchctlPrintOutput.pid(in: output) == nil)
  }
}
