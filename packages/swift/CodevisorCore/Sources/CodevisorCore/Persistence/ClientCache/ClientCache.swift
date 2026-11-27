import Foundation

public final class ClientCache: Sendable {
  public static let filesDirectoryName = "ClientCacheFiles"

  let database: ClientDatabase
  let files: ClientCacheFiles
  let limits: ClientCacheLimits
  let auditsWrites: Bool

  private let work = CoalescingWorkQueue(label: "com.codevisor.client-cache")
  private let written = NavigationWriteHistory()
  private let writesSinceTrim = WriteCounter()
  private let now: @Sendable () -> Date

  init(
    database: ClientDatabase, filesDirectory: URL, limits: ClientCacheLimits = .standard, auditsWrites: Bool,
    now: @escaping @Sendable () -> Date = Date.init
  ) throws {
    self.database = database
    self.files = ClientCacheFiles(directory: filesDirectory)
    self.limits = limits
    self.auditsWrites = auditsWrites
    self.now = now
    if try ClientCacheSchema.prepare(database) { files.removeAll() }
  }

  public static func open(databaseURL: URL, filesDirectory: URL) -> ClientCache? {
    do {
      let cache = try ClientCache(
        database: try ClientDatabase(url: databaseURL), filesDirectory: filesDirectory,
        auditsWrites: CodevisorAppVariant.isDevelopment)
      cache.trim()
      return cache
    } catch {
      Log.clientCache.error("Client cache is unavailable: \(String(describing: error), privacy: .public)")
      return nil
    }
  }

  public func recordNavigation(_ snapshot: ServerNavigationSnapshot, machineId: String) {
    enqueue("navigation.\(machineId)") { cache in
      let previous = cache.written.previous(machineId: machineId)
      try cache.navigation.write(snapshot, over: previous, machineId: machineId, at: cache.now())
      cache.written.record(snapshot, machineId: machineId)
      cache.auditNavigation(snapshot, machineId: machineId)
    }
  }

  public func forgetMachine(_ machineId: String) {
    enqueue("navigation.\(machineId)") { cache in
      try cache.navigation.remove(machineId: machineId)
      cache.written.record(nil, machineId: machineId)
    }
  }

  func recordOpenedTranscript(_ data: Data, chat: CachedChatKey) {
    enqueueInOrder("transcript.head.\(chat.machineId).\(chat.chatId)") { cache in
      try cache.transcripts.writeHead(try .opened(data), chat: chat, opened: true, at: cache.now())
      cache.noteWrite()
    }
  }

  func recordTranscriptPage(_ data: Data, before: String?, chat: CachedChatKey) {
    guard let before else { return recordHeadPage(data, chat: chat) }

    enqueueInOrder("transcript.older.\(chat.machineId).\(chat.chatId)") { cache in
      try cache.transcripts.writeOlder(try .page(data), before: before, chat: chat, at: cache.now())
      cache.noteWrite()
    }
  }

  func recordFile(_ data: Data, variant: AttachmentCacheTables.Variant, file: CachedFileKey) {
    guard data.count <= limits.largestFileBytes else { return }

    enqueue("file.\(file.machineId).\(file.fileId).\(variant.rawValue)") { cache in
      let name = AttachmentCacheTables.fileName(for: file, variant: variant)
      try cache.files.write(data, named: name)
      try cache.attachments.recordFile(named: name, bytes: data.count, variant: variant, file: file, at: cache.now())
      cache.noteWrite()
    }
  }

  func recordQueuedSends(_ sends: [CachedQueuedSend], chat: CachedChatKey) {
    enqueue("sends.\(chat.machineId).\(chat.chatId)") { cache in
      try cache.queuedSends.replace(sends, in: chat, at: cache.now())
    }
  }

  func auditTranscript(shown: [UUID], chat: CachedChatKey, transport: ServerSessionTransport) {
    guard auditsWrites else { return }

    enqueue("audit.\(chat.machineId).\(chat.chatId)") { cache in
      let cached = try cache.transcripts.page(of: chat).map { data in
        transport.historyPage(from: try JSONDecoder().decode(ServerTranscriptPage.self, from: data)).conversation.map(
          \.id)
      }
      let result = ClientCacheAudit.transcript(cached: cached, shown: shown, chat: chat)
      ClientCacheAudit.log(result, detail: "\(shown.count) shown items, \(cached?.count ?? 0) cached")
    }
  }

  func loadNavigation() -> [String: ServerNavigationSnapshot] {
    do {
      let snapshots = try navigation.snapshots()
      for (machineId, snapshot) in snapshots { written.record(snapshot, machineId: machineId) }
      return snapshots
    } catch {
      recover(from: error, during: "navigation.load")
      return [:]
    }
  }

  func adoptLegacyNavigation(_ snapshots: [String: ServerNavigationSnapshot]) throws {
    guard try navigation.machineIds().isEmpty else { return }

    for (machineId, snapshot) in snapshots {
      try navigation.write(snapshot, over: nil, machineId: machineId, at: now())
    }
  }

  func transcriptPage(of chat: CachedChatKey) async -> Data? {
    await work.perform { [self] in
      do {
        try transcripts.markOpened(chat, at: now())
        return try transcripts.page(of: chat)
      } catch {
        recover(from: error, during: "transcript.load")
        return nil
      }
    }
  }

  func forgetTranscript(_ chat: CachedChatKey) {
    enqueueInOrder("transcript.forget.\(chat.machineId).\(chat.chatId)") { cache in
      try cache.transcripts.remove(chat)
    }
  }

  private func storedFile(_ file: CachedFileKey, variant: AttachmentCacheTables.Variant) -> Data? {
    guard let name = try? attachments.fileName(of: file, variant: variant) else { return nil }
    guard let data = files.read(named: name) else {
      try? attachments.forgetFile(file, variant: variant)
      return nil
    }
    try? attachments.touch(file, at: now())
    return data
  }

  func flush() async {
    await work.flush()
  }

  var navigation: NavigationCacheTables { NavigationCacheTables(database: database) }
  var transcripts: TranscriptCacheTables { TranscriptCacheTables(database: database) }
  var attachments: AttachmentCacheTables { AttachmentCacheTables(database: database) }
  var queuedSends: QueuedSendCacheTables { QueuedSendCacheTables(database: database) }

  private func recordHeadPage(_ data: Data, chat: CachedChatKey) {
    enqueueInOrder("transcript.head.\(chat.machineId).\(chat.chatId)") { cache in
      try cache.transcripts.writeHead(try .page(data), chat: chat, opened: false, at: cache.now())
      cache.noteWrite()
    }
  }

  private func enqueueInOrder(_ label: String, _ job: @escaping @Sendable (ClientCache) throws -> Void) {
    enqueue("\(label).\(UUID().uuidString)", job)
  }

  private func enqueue(_ key: String, _ job: @escaping @Sendable (ClientCache) throws -> Void) {
    work.enqueue(key: key) { [self] in
      do {
        try job(self)
      } catch {
        recover(from: error, during: key)
      }
    }
  }

  private func recover(from error: any Error, during key: String) {
    Log.clientCache.error(
      "Client cache write \(key, privacy: .public) failed; rebuilding the cache: \(String(describing: error), privacy: .public)"
    )
    let snapshots = written.takeAll()
    do {
      try ClientCacheSchema.rebuild(database)
      files.removeAll()
      for (machineId, snapshot) in snapshots { recordNavigation(snapshot, machineId: machineId) }
    } catch {
      Log.clientCache.fault("Client cache could not be rebuilt: \(String(describing: error), privacy: .public)")
    }
  }

  private func auditNavigation(_ snapshot: ServerNavigationSnapshot, machineId: String) {
    guard auditsWrites else { return }

    let result = ClientCacheAudit.navigation(
      cached: try? navigation.snapshot(machineId: machineId), expected: snapshot, machineId: machineId)
    ClientCacheAudit.log(
      result, detail: "\(snapshot.workspaces.count) workspaces, \(snapshot.sessions.count) chats")
  }

  private func noteWrite() {
    guard writesSinceTrim.increment() >= Self.writesPerTrim else { return }

    trim()
  }

  func trim() {
    writesSinceTrim.reset()
    enqueue("trim") { cache in
      cache.files.remove(
        named: try ClientCacheTrim(database: cache.database, limits: cache.limits).run(at: cache.now()))
    }
  }

  private static let writesPerTrim = 50
}

extension ClientCache: ServerFileCaching {
  public func cachedFile(machineId: String, fileId: String, preview: Bool) async -> Data? {
    let file = CachedFileKey(machineId: machineId, fileId: fileId)
    let variant: AttachmentCacheTables.Variant = preview ? .preview : .original
    return await work.perform { [self] in storedFile(file, variant: variant) }
  }

  public func cacheFile(_ data: Data, machineId: String, fileId: String, preview: Bool) {
    recordFile(data, variant: preview ? .preview : .original, file: CachedFileKey(machineId: machineId, fileId: fileId))
  }
}
