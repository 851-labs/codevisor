import Foundation
import Testing
@testable import CodevisorCoreMac

@Suite("LegacyServerJobRetirer")
struct LegacyServerJobRetirerTests {
    @Test("Removes and verifies every updater-era launchd job")
    func removesEveryLegacyJob() async throws {
        let runner = RecordingLaunchctlRunner(printExitCode: 113)
        let retirer = LegacyServerJobRetirer(runner: runner, userID: 501)

        try await retirer.retire()

        let invocations = await runner.invocations
        #expect(invocations.count == LegacyServerJobRetirer.labels.count * 2)
        for label in LegacyServerJobRetirer.labels {
            #expect(invocations.contains(["remove", label]))
            #expect(invocations.contains(["print", "gui/501/\(label)"]))
        }
    }

    @Test("Fails when launchd still reports a legacy job")
    func reportsJobThatSurvivedRemoval() async {
        let runner = RecordingLaunchctlRunner(printExitCode: 0)
        let retirer = LegacyServerJobRetirer(runner: runner, userID: 501)

        await #expect(throws: LegacyServerJobRetirementError.self) {
            try await retirer.retire()
        }
    }
}

private actor RecordingLaunchctlRunner: CommandRunner {
    let printExitCode: Int32
    private(set) var invocations: [[String]] = []

    init(printExitCode: Int32) {
        self.printExitCode = printExitCode
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?
    ) async throws -> CommandResult {
        invocations.append(arguments)
        return CommandResult(
            standardOutput: "",
            standardError: "",
            exitCode: arguments.first == "print" ? printExitCode : 0
        )
    }
}
