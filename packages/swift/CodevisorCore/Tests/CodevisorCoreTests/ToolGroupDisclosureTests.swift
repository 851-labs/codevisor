import Testing
@testable import CodevisorCore

@Suite("Tool group disclosure")
@MainActor
struct ToolGroupDisclosureTests {
  @Test("Tool groups start collapsed, and the session store retains each group's choice across remounts")
  func disclosureIdentitySurvivesRemount() {
    let store = TranscriptDisclosureStore()
    let first = store.toolGroupDisclosure(id: "group")
    #expect(!first.isExpanded)
    first.userToggled()

    let remounted = store.toolGroupDisclosure(id: "group")
    #expect(first === remounted)
    #expect(remounted.isExpanded)
    #expect(!store.toolGroupDisclosure(id: "another-group").isExpanded)

    remounted.userToggled()
    #expect(!store.toolGroupDisclosure(id: "group").isExpanded)
  }
}
