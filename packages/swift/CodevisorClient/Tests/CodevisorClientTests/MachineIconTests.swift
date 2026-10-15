import CodevisorClient
import Foundation
import Testing

@Suite("Machine icons")
struct MachineIconTests {
  private func cloudMachine(icon: String?) -> CodevisorMachine {
    CodevisorMachine(
      id: "cloud:studio",
      name: "Studio",
      baseURL: CodevisorMachine.cloudPlaceholderBaseURL,
      kind: "cloud",
      icon: icon
    )
  }

  @Test("A machine's reported icon is resolved when the machine is built")
  func chosenIcon() {
    #expect(cloudMachine(icon: "macstudio").icon.systemImage == "macstudio")
    #expect(cloudMachine(icon: "macstudio").icon.title == "Mac Studio")
  }

  @Test("A missing or unknown icon resolves to the fallback choice")
  func unknownIcons() {
    #expect(MachineIcon.choices.contains(MachineIcon.fallback))
    #expect(cloudMachine(icon: nil).icon == MachineIcon.fallback)
    #expect(cloudMachine(icon: "not.a.machine.icon").icon == MachineIcon.fallback)
  }

  @Test("A saved filled cloud resolves to the outline Cloud choice")
  func legacyFilledCloud() {
    #expect(cloudMachine(icon: "cloud.fill").icon.systemImage == "cloud")
    #expect(MachineIcon.choices.allSatisfy { !$0.systemImage.hasSuffix(".fill") })
  }

  @Test("Only icons this client knows count as chosen")
  func knownIcons() {
    #expect(MachineIcon(known: "macmini")?.title == "Mac mini")
    #expect(MachineIcon(known: "cloud.fill")?.systemImage == "cloud")
    #expect(MachineIcon(known: "macbook.gen2") == nil)
    #expect(MachineIcon(known: nil) == nil)
  }
}
