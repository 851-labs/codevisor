import Foundation
import Observation
import ACPKit

@MainActor
@Observable
final class SessionHistoryPaging {
  var hasOlderPages = false
  var isLoadingOlderPage = false
  @ObservationIgnored var olderPageCursor: String?
  @ObservationIgnored var isPaginated = false

  var canLoadOlderPage: Bool {
    isPaginated && !isLoadingOlderPage
  }

  func adopt(_ page: TranscriptHistoryPage) {
    olderPageCursor = page.nextBefore
    hasOlderPages = page.hasMore
  }

  nonisolated static func olderItems(
    in shown: [ConversationItem]?, before page: TranscriptHistoryPage
  ) -> [ConversationItem]? {
    guard let shown, let first = page.conversation.first,
      let end = shown.firstIndex(where: { $0.id == first.id })
    else { return nil }
    return Array(shown.prefix(end))
  }
}
