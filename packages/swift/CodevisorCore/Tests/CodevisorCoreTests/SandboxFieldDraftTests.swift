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

    #expect(optional.emptyPrompt == "Optional")
    #expect(defaulted.emptyPrompt == "debian")
    #expect(required.emptyPrompt == "https://…")
  }

  @Test("A field another field replaces is named as coming from it only while that field is filled in")
  func replacedFields() {
    let snapshot = ServerSandboxField(key: "snapshot", label: "Snapshot", type: .string)
    let cpu = ServerSandboxField(key: "cpu", label: "CPUs", type: .number, replacedBy: "snapshot")
    var draft = SandboxFieldDraft(fields: [snapshot, cpu], values: [:])

    let whileEmpty = draft.replacement(of: cpu, among: [snapshot, cpu])
    draft.text["snapshot"] = "  "
    let whileBlank = draft.replacement(of: cpu, among: [snapshot, cpu])
    draft.text["snapshot"] = "base"

    #expect(whileEmpty == nil)
    #expect(whileBlank == nil)
    #expect(draft.replacement(of: cpu, among: [snapshot, cpu]) == snapshot)
    #expect(draft.replacement(of: snapshot, among: [snapshot, cpu]) == nil)
  }
}
