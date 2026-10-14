import Foundation
import Testing

@testable import CodevisorClient

@Suite("Unresolved machine")
struct UnresolvedMachineTests {
  @Test func anUnresolvedMachineKeepsItsIdentityAndIsNeverLocal() {
    let machine = CodevisorMachine.unresolved(id: "stage3v")

    #expect(machine.id == "stage3v")
    #expect(!machine.isLocal)
    #expect(machine.id != CodevisorMachine.local.id)
    #expect(machine.baseURL != CodevisorMachine.local.baseURL)
    #expect(machine.baseURL.host() == "unresolved.invalid")
  }
}
