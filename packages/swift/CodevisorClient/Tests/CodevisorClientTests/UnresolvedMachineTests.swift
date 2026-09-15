import Foundation
import Testing

@testable import CodevisorClient

/// A workspace addressed without a chat still names its own machine. When that
/// machine cannot be resolved, its panes must report unavailable rather than
/// quietly addressing a different machine — above all this one, which is what
/// falling back to `CodevisorMachine.local` would do.
@Suite("Unresolved machine")
struct UnresolvedMachineTests {
  @Test func anUnresolvedMachineKeepsItsIdentityAndIsNeverLocal() {
    let machine = CodevisorMachine.unresolved(id: "stage3v")

    #expect(machine.id == "stage3v")  // the real server id, not a substitute
    #expect(!machine.isLocal)
    #expect(machine.isUnresolved)
    #expect(machine.id != CodevisorMachine.local.id)
    #expect(machine.baseURL != CodevisorMachine.local.baseURL)
    // A reserved name that cannot resolve, so a request fails instead of
    // reaching some other server.
    #expect(machine.baseURL.host() == "unresolved.invalid")
    #expect(machine.token == nil)
  }

  @Test func theLocalMachineIsNotMistakenForAnUnresolvedOne() {
    #expect(CodevisorMachine.local.isLocal)
    #expect(!CodevisorMachine.local.isUnresolved)
  }
}
