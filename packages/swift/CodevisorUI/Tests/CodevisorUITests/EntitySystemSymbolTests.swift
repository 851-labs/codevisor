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
}
