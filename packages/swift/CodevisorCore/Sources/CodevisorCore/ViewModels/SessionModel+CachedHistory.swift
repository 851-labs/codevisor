import Foundation

extension SessionModel {
  /// Paints a transcript page saved on this device, before the server's
  /// fresh page arrives. Nothing streams from it: the live consumer starts
  /// from the fresh page's cursor, which then replaces these items in place.
  func showCachedHistory(_ page: TranscriptHistoryPage) {
    guard conversation.isEmpty else { return }
    usesPaginatedHistory = true
    olderHistoryCursor = page.nextBefore
    hasOlderHistory = page.hasMore
    setConversation(page.conversation)
  }
}
