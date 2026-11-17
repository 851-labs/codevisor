import CodevisorClient
import Testing

@testable import CodevisorCore

@Suite("Sandbox fields while they are filled in")
struct SandboxFieldDraftTests {
  @Test("An empty optional field says so, and one with a default or an example shows that instead")
  func emptyPrompts() {
    let optional = ServerSandboxField(key: "snapshot", label: "Snapshot", type: .string, placeholder: "us")
    let defaulted = ServerSandboxField(key: "image", label: "Image", type: .string, defaultValue: .string("debian"))
    let required = ServerSandboxField(key: "url", label: "URL", type: .url, required: true, placeholder: "https://…")
    let bare = ServerSandboxField(key: "token", label: "Token", type: .secret, required: true)

    #expect(optional.emptyPrompt == "Optional")
    #expect(defaulted.emptyPrompt == "debian")
    #expect(required.emptyPrompt == "https://…")
    #expect(bare.emptyPrompt.isEmpty)
  }

  @Test("A field another field replaces is left out only while that field is filled in")
  func replacedFields() {
    let snapshot = ServerSandboxField(key: "snapshot", label: "Snapshot", type: .string)
    let cpu = ServerSandboxField(key: "cpu", label: "CPUs", type: .number, replacedBy: "snapshot")
    var draft = SandboxFieldDraft(fields: [snapshot, cpu], values: ["cpu": .number(4)])

    let whileEmpty = draft.isReplaced(cpu)
    draft.text["snapshot"] = "  "
    let whileBlank = draft.isReplaced(cpu)
    draft.text["snapshot"] = "base"
    let whileSet = draft.isReplaced(cpu)
    draft.text["snapshot"] = ""

    #expect(!whileEmpty && !whileBlank)
    #expect(whileSet)
    #expect(!draft.isReplaced(snapshot))
    #expect(draft.text["cpu"] == "4")
  }
}
