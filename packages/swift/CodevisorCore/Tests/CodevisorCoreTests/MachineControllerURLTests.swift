import Foundation
import Testing

@testable import CodevisorCore

/// Host-input normalization for Add Remote Machine. Split from
/// `MachineControllerTests` so that suite stays within the size ratchet.
@MainActor
@Suite("MachineController URL normalization")
struct MachineControllerURLTests {
  @Test("Remote host input normalizes to an HTTP server URL")
  func normalizedRemoteURL() throws {
    #expect(
      try MachineController.normalizedRemoteURL(from: "mac-mini.tailnet.ts.net").absoluteString
        == "http://mac-mini.tailnet.ts.net:49361")
    #expect(
      try MachineController.normalizedRemoteURL(from: "https://10.0.0.5:9999/path?x=1").absoluteString
        == "https://10.0.0.5:9999")
    #expect(throws: MachineControllerError.invalidHost(" ")) {
      _ = try MachineController.normalizedRemoteURL(from: " ")
    }
  }
}
