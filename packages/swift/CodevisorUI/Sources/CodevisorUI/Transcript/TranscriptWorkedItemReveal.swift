import CodevisorCore
import TranscriptKit

@MainActor
public enum TranscriptWorkedItemReveal {
  public static func expand(_ location: TranscriptWorkedItemLocation, in disclosure: TranscriptDisclosureStore) {
    let section = location.section
    disclosure.setExpanded(section.kind.disclosureKey(messageID: section.messageID), true)
    if location.isEarlierHistory {
      disclosure.setExpanded(section.kind.earlierHistoryDisclosureKey(messageID: section.messageID), true)
    }
    if let toolGroupID = location.toolGroupID {
      disclosure.toolGroupDisclosure(id: toolGroupID).expand()
    }
  }
}
