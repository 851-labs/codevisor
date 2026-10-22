import Foundation

extension SessionModel {
  func showCachedHistory(_ page: TranscriptHistoryPage) {
    guard conversation.isEmpty else { return }
    historyPaging.isPaginated = true
    historyPaging.adopt(page)
    setConversation(page.conversation)
  }
}
