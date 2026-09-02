import CodevisorClient
import Foundation
import Testing
@testable import CodevisorUI

@Suite("Entity system symbols")
struct EntitySystemSymbolTests {
  @Test("Machine symbols distinguish local, cloud, and direct machines")
  func machineSymbols() {
    let cloud = CodevisorMachine(
      id: "cloud:studio",
      name: "Studio",
      baseURL: CodevisorMachine.cloudPlaceholderBaseURL,
      kind: "remote"
    )
    let remote = CodevisorMachine(
      id: "remote-studio",
      name: "Studio",
      baseURL: URL(string: "http://studio.local")!,
      kind: "remote"
    )

    #expect(EntitySystemSymbol.machine(.local) == "desktopcomputer")
    #expect(EntitySystemSymbol.machine(cloud) == "cloud.fill")
    #expect(EntitySystemSymbol.machine(remote) == "globe.fill")
  }
}
