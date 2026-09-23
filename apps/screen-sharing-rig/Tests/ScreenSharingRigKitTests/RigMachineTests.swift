import Foundation
import Testing

@testable import ScreenSharingRigKit

struct RigMachineTests {
  @Test func catalogIdsAreUniqueAndLeaveRoomForTheLoopbackServer() {
    let ids = RigMachine.catalog.map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(ids.contains("contabo-vps"))
    #expect(!ids.contains(RigMachine.loopback(port: 1, password: nil).id))
  }

  @Test func tokenCommandNeverPromptsAndRunsCodevisorToken() {
    #expect(
      RigMachine.tokenCommandArguments(sshTarget: "root@m") == [
        "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "root@m", "codevisor", "token",
      ])
  }

  @Test func loopbackIsADirectVNCMachineOnItsPort() {
    let machine = RigMachine.loopback(port: 50123, password: "secret")
    #expect(machine.connection == .vnc(host: "127.0.0.1", port: 50123, password: "secret"))
    #expect(RigMachine.vncDisplayId(port: 50123) == "vnc:50123")
  }
}
