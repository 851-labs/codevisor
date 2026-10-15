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

  @Test("An icon round-trips through JSON as its symbol name")
  func codable() throws {
    let data = try JSONEncoder().encode(MachineIcon(resolving: "macmini"))
    #expect(String(decoding: data, as: UTF8.self) == "\"macmini\"")
    #expect(try JSONDecoder().decode(MachineIcon.self, from: Data("\"cloud.fill\"".utf8)).systemImage == "cloud")
  }
}
