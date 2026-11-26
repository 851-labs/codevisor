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

  func recordQueuedSends(_ unsent: [SendQueue.Unsent]) {
    cache.recordQueuedSends(unsent.map(CachedQueuedSend.init), chat: chat)
  }

  @MainActor
  func audit(_ model: SessionModel) {
    cache.auditTranscript(shown: model.conversation.map(\.id), chat: chat, transport: model.transport)
  }
}
