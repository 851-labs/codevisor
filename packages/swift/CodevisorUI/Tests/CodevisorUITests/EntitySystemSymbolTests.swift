import CodevisorClient
import Foundation
import Testing
@testable import CodevisorUI

@Suite("Entity system symbols")
struct EntitySystemSymbolTests {
  @Test("Machine symbols distinguish this Mac from account machines")
  func machineSymbols() {
    let cloud = CodevisorMachine(
      id: "cloud:studio",
      name: "Studio",
      baseURL: CodevisorMachine.cloudPlaceholderBaseURL,
      kind: "cloud"
    )

    #expect(EntitySystemSymbol.machine(.local) == "desktopcomputer")
    #expect(EntitySystemSymbol.machine(cloud) == "cloud.fill")
  }

  @Test("A machine's chosen icon wins, and unknown icons fall back to the default")
  func chosenMachineIcons() {
    var cloud = CodevisorMachine(
      id: "cloud:studio",
      name: "Studio",
      baseURL: CodevisorMachine.cloudPlaceholderBaseURL,
      kind: "cloud",
      icon: "macstudio"
    )
    #expect(EntitySystemSymbol.machine(cloud) == "macstudio")

    cloud.icon = "not.a.machine.icon"
    #expect(EntitySystemSymbol.machine(cloud) == "cloud.fill")
  }
}
