import Foundation
import Testing

@testable import ScreenSharing

struct ScreenSharingDiagnosticProfileParsingTests {
  @Test(arguments: [
    " ", "\t", "\n", "paced15-worker\n", "paced15-worker\t", "\"paced15-worker\"", "'paced15-worker'",
    "paced15-worker=1", "paced15_worker", "paced15-worker,paced15-worker", "yes", "0", "none",
    "paced15", "paced15-worker ", " paced15-worker", "Paced15-Worker", "PACED15-WORKER", "1", "true", "off",
    "default", "paced35-worker",
  ])
  func aValueThatIsNotTheExactNameFailsAndSaysWhatToDoInstead(_ raw: String) throws {
    let environment = [ScreenSharingDiagnosticProfile.environmentKey: raw]
    do {
      let resolved = try ScreenSharingDiagnosticProfile.resolve(environment: environment)
      Issue.record("\(raw.debugDescription) resolved to \(String(describing: resolved)) instead of failing")
    } catch ScreenSharingError.invalid(let message) {
      #expect(message.contains(ScreenSharingDiagnosticProfile.environmentKey))
      #expect(message.contains("\"\(raw)\""))
      #expect(message.contains("\"\(ScreenSharingDiagnosticProfile.paced15WorkerName)\""))
    }
  }

  @Test(arguments: [
    "codevisor_screen_sharing_diagnostic_profile", "CODEVISOR_SCREEN_SHARING_DIAGNOSTIC_PROFILE ",
    "CODEVISOR_SCREEN_SHARING_DIAGNOSTIC_PROFILE_2", "SCREEN_SHARING_DIAGNOSTIC_PROFILE",
  ])
  func aLookalikeKeyLeavesTheProfileOff(_ key: String) throws {
    let environment = [key: ScreenSharingDiagnosticProfile.paced15WorkerName, "PATH": "/usr/bin"]
    #expect(try ScreenSharingDiagnosticProfile.resolve(environment: environment) == nil)
  }

  @Test func anAbsentOrEmptyVariableLeavesTheProfileOff() throws {
    #expect(try ScreenSharingDiagnosticProfile.resolve(environment: [:]) == nil)
    #expect(
      try ScreenSharingDiagnosticProfile.resolve(environment: [ScreenSharingDiagnosticProfile.environmentKey: ""])
        == nil)
  }

  @Test func theOneKnownNameSelectsTheProfileWhateverElseTheEnvironmentHolds() throws {
    let environment = [
      ScreenSharingDiagnosticProfile.environmentKey: ScreenSharingDiagnosticProfile.paced15WorkerName,
      "CODEVISOR_SCREEN_SHARING_DIAGNOSTIC_PROFILE_OLD": "paced35-worker",
      "PATH": "/usr/bin",
    ]
    let selected = try ScreenSharingDiagnosticProfile.resolve(environment: environment)
    let resolved = try #require(selected)
    #expect(resolved == .paced15Worker)
    #expect(try ScreenSharingDiagnosticProfile.resolve(environment: environment) == resolved)
  }

  @Test func theProcessProfileAgreesWithTheParserAndNeverChangesWithinAProcess() {
    func outcome(_ body: () throws -> ScreenSharingDiagnosticProfile?) -> String {
      do { return try body()?.name ?? "off" } catch { return "failure: \(error.localizedDescription)" }
    }
    let live = outcome { try ScreenSharingDiagnosticProfile.resolve(environment: ProcessInfo.processInfo.environment) }
    #expect(outcome { try ScreenSharingDiagnosticProfile.process() } == live)
    #expect(outcome { try ScreenSharingDiagnosticProfile.process() } == live)
  }
}
