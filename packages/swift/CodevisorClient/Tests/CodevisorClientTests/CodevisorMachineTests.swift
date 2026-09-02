import Foundation
import Testing
@testable import CodevisorClient

@Suite("Codevisor machine")
struct CodevisorMachineTests {
  @Test("The local machine uses the computer name as its display name")
  func localMachineName() {
    #if os(macOS)
      #expect(CodevisorMachine.local.name == (Host.current().localizedName ?? "Local Codevisor"))
    #else
      #expect(CodevisorMachine.local.name == ProcessInfo.processInfo.hostName)
    #endif
  }
}
