import Foundation
import Testing

@testable import ScreenSharing

/// The profile is default-off and selected only by an exact environment value, so the parser's job
/// is mostly refusal: everything that is not the one spelling has to fail loudly rather than turn
/// the diagnostic on — or, worse, leave it off while the operator believes it is on.
///
/// Nothing here mutates the process environment. `resolve(environment:)` is the seam that exists so
/// the parser can be tested without it, and `setenv` from a test running beside others that read
/// `ProcessInfo.processInfo.environment` is a race, not a fixture.
struct ScreenSharingDiagnosticProfileParsingTests {
  /// Values a shell, a plist or a file read can easily produce. None of them is the profile.
  @Test(arguments: [
    " ", "\t", "\n", "paced15-worker\n", "paced15-worker\t", "\"paced15-worker\"", "'paced15-worker'",
    "paced15-worker=1", "paced15_worker", "paced15-worker,paced15-worker", "yes", "0", "none",
  ])
  func aValueThatIsNotTheExactNameFailsAndSaysWhatToDoInstead(_ raw: String) throws {
    let environment = [ScreenSharingDiagnosticProfile.environmentKey: raw]
    do {
      let resolved = try ScreenSharingDiagnosticProfile.resolve(environment: environment)
      Issue.record("\(raw.debugDescription) resolved to \(String(describing: resolved)) instead of failing")
    } catch ScreenSharingError.invalid(let message) {
      // The message is the operator's only feedback, so it has to name the variable, quote what was
      // found, and give the one accepted spelling.
      #expect(message.contains(ScreenSharingDiagnosticProfile.environmentKey))
      #expect(message.contains("\"\(raw)\""))
      #expect(message.contains("\"\(ScreenSharingDiagnosticProfile.paced15WorkerName)\""))
    }
  }

  /// Only this key selects the profile. A near-miss key is not a hint to turn anything on.
  @Test(arguments: [
    "codevisor_screen_sharing_diagnostic_profile", "CODEVISOR_SCREEN_SHARING_DIAGNOSTIC_PROFILE ",
    "CODEVISOR_SCREEN_SHARING_DIAGNOSTIC_PROFILE_2", "SCREEN_SHARING_DIAGNOSTIC_PROFILE",
  ])
  func aLookalikeKeyLeavesTheProfileOff(_ key: String) throws {
    let environment = [key: ScreenSharingDiagnosticProfile.paced15WorkerName, "PATH": "/usr/bin"]
    #expect(try ScreenSharingDiagnosticProfile.resolve(environment: environment) == nil)
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
    // Resolution is pure: the same environment always produces the same profile.
    #expect(try ScreenSharingDiagnosticProfile.resolve(environment: environment) == resolved)
  }

  /// The process profile is parsed once and replayed, including a failure. Whatever this machine's
  /// environment holds, every caller must get the same answer as the pure parser gives for it —
  /// otherwise two roles in one process could disagree about whether the diagnostic is on.
  @Test func theProcessProfileAgreesWithTheParserAndNeverChangesWithinAProcess() {
    func outcome(_ body: () throws -> ScreenSharingDiagnosticProfile?) -> String {
      do { return try body()?.name ?? "off" } catch { return "failure: \(error.localizedDescription)" }
    }
    let live = outcome { try ScreenSharingDiagnosticProfile.resolve(environment: ProcessInfo.processInfo.environment) }
    #expect(outcome { try ScreenSharingDiagnosticProfile.process() } == live)
    #expect(outcome { try ScreenSharingDiagnosticProfile.process() } == live)
  }
}
