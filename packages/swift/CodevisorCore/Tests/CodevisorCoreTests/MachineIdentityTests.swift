import Testing

@testable import CodevisorCore

@Suite("This Mac under other machine entries")
struct MachineIdentityTests {
  private func status(serverId: String?) -> MachineStatus {
    MachineStatus(isReachable: true, label: "Mac", serverId: serverId)
  }

  @Test("The local entry is always this Mac")
  func localEntry() {
    #expect(codevisorMachineIsThisMac(CodevisorMachine.local.id, statusByMachineId: [:]))
  }

  @Test("A configured or cloud entry that probed as the local server is this Mac")
  func sameServer() {
    let statuses = [
      CodevisorMachine.local.id: status(serverId: "de7094fd"),
      "cloud:device-1": status(serverId: "de7094fd"),
      "remote-2": status(serverId: "other"),
      "remote-3": status(serverId: nil),
    ]
    #expect(codevisorMachineIsThisMac("cloud:device-1", statusByMachineId: statuses))
    #expect(!codevisorMachineIsThisMac("remote-2", statusByMachineId: statuses))
    // Unknown identity is never assumed local.
    #expect(!codevisorMachineIsThisMac("remote-3", statusByMachineId: statuses))
    #expect(!codevisorMachineIsThisMac("unprobed", statusByMachineId: statuses))
    #expect(
      !codevisorMachineIsThisMac(
        "cloud:device-1", statusByMachineId: ["cloud:device-1": status(serverId: "de7094fd")]))
  }
}
