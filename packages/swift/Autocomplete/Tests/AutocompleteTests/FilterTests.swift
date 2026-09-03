import Testing
@testable import Autocomplete

@Suite("Autocomplete filter")
struct FilterTests {
  @Test("contains is case- and diacritic-insensitive")
  func contains() {
    #expect(Autocomplete.Filter.contains.matches("Claude Code", query: "code"))
    #expect(Autocomplete.Filter.contains.matches("Résumé", query: "resume"))
    #expect(!Autocomplete.Filter.contains.matches("Codex", query: "claude"))
  }

  @Test("startsWith anchors at the beginning")
  func startsWith() {
    #expect(Autocomplete.Filter.startsWith.matches("Gemini CLI", query: "gem"))
    #expect(!Autocomplete.Filter.startsWith.matches("Gemini CLI", query: "cli"))
  }

  @Test("subsequence accepts scattered characters in order")
  func subsequence() {
    #expect(Autocomplete.Filter.subsequence.matches("Open Recent Project", query: "orp"))
    #expect(!Autocomplete.Filter.subsequence.matches("Open Recent Project", query: "tcp"))
    #expect(Autocomplete.Filter.subsequence.matches("anything", query: ""))
  }
}
