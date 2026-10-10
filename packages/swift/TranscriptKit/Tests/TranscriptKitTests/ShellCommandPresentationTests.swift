import ACPKit
import Testing
@testable import TranscriptKit

@Suite("Shell command presentation")
struct ShellCommandPresentationTests {
  private func shell(_ input: JSONValue?, kind: ToolKind = .execute) -> ToolCall {
    ToolCall(toolCallId: "sh", title: "Ran", kind: kind, status: .completed, rawInput: input)
  }

  @Test("Shows the whole script a harness reported, in any of its shapes")
  func reportedShapes() {
    #expect(shell(["command": "cat notes.txt\necho done\n"]).shellCommand == "cat notes.txt\necho done")
    #expect(shell(["cmd": "pwd"]).shellCommand == "pwd")
    #expect(shell(["command": ["git", "status", "--short"]]).shellCommand == "git status --short")
    #expect(shell(["command": ["/bin/bash", "-lc", "rg -n foo"]]).shellCommand == "rg -n foo")
    // Nothing to echo: no input, an empty command, or a non-shell call.
    #expect(shell(nil).shellCommand == nil)
    #expect(shell(["command": "  "]).shellCommand == nil)
    #expect(shell(["description": "Lists files"]).shellCommand == nil)
    #expect(shell(["command": "ls"], kind: .read).shellCommand == nil)
  }

  @Test("Unwraps a login-shell invocation to the script it runs")
  func loginShellWrappers() {
    #expect(ToolCall.unwrappingShellInvocation("/bin/zsh -lc 'rg -n \"x\" src'") == "rg -n \"x\" src")
    #expect(ToolCall.unwrappingShellInvocation(#"bash -c 'echo '\''hi'\'''"#) == "echo 'hi'")
    #expect(ToolCall.unwrappingShellInvocation(#"sh -c 'it'"'"'s'"#) == "it's")
    #expect(ToolCall.unwrappingShellInvocation(#"/bin/bash -lc "echo \"\$HOME\" \\n""#) == #"echo "$HOME" \n"#)
    // Anything that isn't exactly one quoted word stays as the harness wrote it.
    #expect(ToolCall.unwrappingShellInvocation("bash -lc 'a' && 'b'") == "bash -lc 'a' && 'b'")
    #expect(ToolCall.unwrappingShellInvocation(#"bash -c "a" "b""#) == #"bash -c "a" "b""#)
    #expect(ToolCall.unwrappingShellInvocation(#"bash -c "trailing\""#) == #"bash -c "trailing\""#)
    #expect(ToolCall.unwrappingShellInvocation("python -c 'print(1)'") == "python -c 'print(1)'")
  }
}
