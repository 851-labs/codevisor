import CodevisorClient
import Foundation
import Testing
@testable import CodevisorUI

@Suite("Entity system symbols")
struct EntitySystemSymbolTests {
  private func cloudMachine(icon: String? = nil) -> CodevisorMachine {
    CodevisorMachine(
      id: "cloud:studio",
      name: "Studio",
      baseURL: CodevisorMachine.cloudPlaceholderBaseURL,
      kind: "cloud",
      icon: icon
    )
  }

  @Test("A machine without an icon uses one fallback, wherever it runs")
  func machinesWithoutIcon() {
    #expect(MachineIcon.choice(MachineIcon.fallback) != nil)
    #expect(EntitySystemSymbol.machine(.local) == MachineIcon.fallback)
    #expect(EntitySystemSymbol.machine(cloudMachine()) == MachineIcon.fallback)
  }

  @Test("A machine's chosen icon wins, and unknown icons fall back")
  func chosenMachineIcons() {
    #expect(EntitySystemSymbol.machine(cloudMachine(icon: "macstudio")) == "macstudio")
    #expect(EntitySystemSymbol.machine(cloudMachine(icon: "not.a.machine.icon")) == MachineIcon.fallback)
  }

  @Test("A saved filled cloud reads as the outline Cloud choice")
  func legacyFilledCloud() {
    #expect(EntitySystemSymbol.machine(cloudMachine(icon: "cloud.fill")) == "cloud")
    #expect(MachineIcon.choices.allSatisfy { !$0.systemImage.hasSuffix(".fill") })
  }
}
