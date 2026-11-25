import Foundation

struct SessionCacheRecorder: Sendable {
  let cache: ClientCache
  let chat: CachedChatKey

  init(cache: ClientCache, machineId: String, chatId: UUID) {
    self.cache = cache
    self.chat = CachedChatKey(machineId: machineId, chatId: chatId)
  }

  func recordingPages(of transport: ServerSessionTransport) -> ServerSessionTransport {
    var transport = transport
    transport.onPageReceived = { [cache, chat] data, before in
      cache.recordTranscriptPage(data, before: before, chat: chat)
    }
    return transport
  }

  func recordOpened(_ data: Data) {
    cache.recordOpenedTranscript(data, chat: chat)
  }

  func recordFile(_ data: Data, from source: PreviewFile.Source, variant: AttachmentCacheTables.Variant) {
    guard case let .attachment(fileId) = source else { return }

    cache.recordFile(data, variant: variant, file: CachedFileKey(machineId: chat.machineId, fileId: fileId))
  }

  func recordQueuedSends(_ unsent: [SendQueue.Unsent]) {
    cache.recordQueuedSends(unsent.map(CachedQueuedSend.init), chat: chat)
  }

  @MainActor
  func audit(_ model: SessionModel) {
    cache.auditTranscript(shown: model.conversation.map(\.id), chat: chat, transport: model.transport)
  }
}
