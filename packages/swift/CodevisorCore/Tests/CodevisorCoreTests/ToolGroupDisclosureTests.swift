import Testing
@testable import CodevisorCore

@Suite("Tool group disclosure")
@MainActor
struct ToolGroupDisclosureTests {
  @Test("Tool groups start collapsed and can be opened and closed manually")
  func manualDisclosure() {
    let disclosure = TranscriptDisclosureStore().toolGroupDisclosure(id: "group")
    #expect(!disclosure.isExpanded)
    disclosure.userToggled()
    #expect(disclosure.isExpanded)
    disclosure.userToggled()
    #expect(!disclosure.isExpanded)
  }

  @Test("Session store retains each group's choice across remounts")
  func disclosureIdentitySurvivesRemount() {
    let store = TranscriptDisclosureStore()
    let first = store.toolGroupDisclosure(id: "group")
    first.userToggled()

    let remounted = store.toolGroupDisclosure(id: "group")
    #expect(first === remounted)
    #expect(remounted.isExpanded)
    #expect(!store.toolGroupDisclosure(id: "another-group").isExpanded)

    remounted.userToggled()
    #expect(!store.toolGroupDisclosure(id: "group").isExpanded)
  }

  @Test("Group choices are scoped to their session")
  func sessionsAreIndependent() {
    let first = TranscriptDisclosureStore()
    first.toolGroupDisclosure(id: "group").userToggled()
    let second = TranscriptDisclosureStore()
    #expect(!second.toolGroupDisclosure(id: "group").isExpanded)
    #expect(first.workedSectionRevision == 0)
  }
}
