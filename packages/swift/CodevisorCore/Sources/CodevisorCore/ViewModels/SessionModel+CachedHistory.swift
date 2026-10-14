import Foundation

extension SessionModel {
  func showCachedHistory(_ page: TranscriptHistoryPage) {
    guard conversation.isEmpty else { return }
    usesPaginatedHistory = true
    olderHistoryCursor = page.nextBefore
    hasOlderHistory = page.hasMore
    setConversation(page.conversation)
  }
}
