import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Client cache")
struct ClientCacheTests {
  @Test("The sidebar the app receives, snapshot then deltas, reads back from the cache tables")
  func sidebarWritesThroughToTables() async throws {
    let fixture = try ClientCacheFixture()
    defer { fixture.tearDown() }
    let cache = try fixture.makeCache()
    let store = NavigationStore(store: InMemoryStore(), clientCache: cache)
    let project = Project.fromFolder(URL(fileURLWithPath: "/fixture/project"), serverId: "local")
    let kept = Self.chat("Kept", project: project)
    let removed = Self.chat("Removed", project: project)
    let snapshot = ServerNavigationSnapshot.fixture(projects: [project], sessions: [kept, removed], cursor: 1)
    var renamed = serverSession(from: kept)
    renamed.title = "Renamed"
    let added = serverSession(from: Self.chat("Added", project: project))
    let delta = ServerNavigationDelta(
      eventCursor: 2, projects: [], sessions: [renamed, added], workspaces: [], panes: [],
      deleted: [try Self.deletion(table: "sessions", id: removed.id.uuidString)])

    await store.replace(snapshot, machineId: "local", requestedAt: Date())
    _ = await store.apply(delta, machineId: "local")
    await cache.flush()

    let cached = try #require(try cache.navigation.snapshot(machineId: "local"))
    #expect(cached == delta.applying(to: snapshot))
    #expect(Set(cached.sessions.map(\.title)) == ["Renamed", "Added"])
  }

  @Test("Forgetting a machine removes everything cached for it")
  func forgettingAMachineClearsItsRows() async throws {
    let fixture = try ClientCacheFixture()
    defer { fixture.tearDown() }
    let cache = try fixture.makeCache()
    let store = NavigationStore(store: InMemoryStore(), clientCache: cache)
    let project = Project.fromFolder(URL(fileURLWithPath: "/fixture/project"), serverId: "local")

    await store.replace(
      .fixture(projects: [project], sessions: [Self.chat("Chat", project: project)]), machineId: "local",
      requestedAt: Date())
    store.forget(machineId: "local")
    await cache.flush()

    #expect(try cache.navigation.snapshot(machineId: "local") == nil)
    #expect(try cache.navigation.machineIds().isEmpty)
  }

  @Test("A cache written by another schema version is wiped with its files, and the app's own stored values survive")
  func schemaMismatchWipesOnlyTheCache() async throws {
    let fixture = try ClientCacheFixture()
    defer { fixture.tearDown() }
    try fixture.database.setPreference(Data("kept".utf8), forKey: "sidebar")
    try fixture.database.setValue(Data("kept".utf8), forKey: "machines")
    let first = try fixture.makeCache()
    let file = CachedFileKey(machineId: "local", fileId: "file-1")
    first.recordNavigation(.fixture(cursor: 7), machineId: "local")
    first.recordFile(Data(repeating: 1, count: 8), variant: .original, file: file)
    await first.flush()
    try fixture.database.run(
      "UPDATE client_metadata SET value = '999' WHERE key = 'client_cache.schema_version'", bindings: [])

    let reopened = try fixture.makeCache()

    #expect(try reopened.navigation.snapshot(machineId: "local") == nil)
    #expect(reopened.files.read(named: AttachmentCacheTables.fileName(for: file, variant: .original)) == nil)
    #expect(try fixture.database.preference(forKey: "sidebar") == Data("kept".utf8))
    #expect(try fixture.database.value(forKey: "machines") == Data("kept".utf8))
  }

  @Test("An attachment the app downloads is kept in the cache")
  func downloadedAttachmentsAreCached() async throws {
    let fixture = try ClientCacheFixture()
    defer { fixture.tearDown() }
    let cache = try fixture.makeCache()
    let bytes = Data(repeating: 7, count: 32)
    let client = CodevisorServerClient(
      config: CodevisorServerConfig(
        baseURL: URL(string: "http://machine.invalid")!, requestTransport: AttachmentTransport(bytes: bytes)),
      machineId: "local", fileCache: cache)

    #expect(try await client.fileData(id: "file-1") == bytes)
    await cache.flush()

    let file = CachedFileKey(machineId: "local", fileId: "file-1")
    let name = try #require(try cache.attachments.fileName(of: file, variant: .original))
    #expect(cache.files.read(named: name) == bytes)
  }

  @Test("The sidebar cached by an older version moves into the cache tables once")
  func legacySidebarIsImported() throws {
    let fixture = try ClientCacheFixture()
    defer { fixture.tearDown() }
    let cache = try fixture.makeCache()
    let store = InMemoryStore()
    let project = Project.fromFolder(URL(fileURLWithPath: "/fixture/project"), serverId: "local")
    let snapshot = ServerNavigationSnapshot.fixture(projects: [project], sessions: [Self.chat("Old", project: project)])
    try store.saveData(JSONEncoder().encode(["local"]), forKey: LegacyNavigationCacheImport.indexKey)
    try store.saveData(JSONEncoder().encode(snapshot), forKey: LegacyNavigationCacheImport.keyPrefix + "local")

    LegacyNavigationCacheImport.run(store: store, cache: cache)

    #expect(cache.loadNavigation()["local"] == snapshot)
    #expect(store.loadData(forKey: LegacyNavigationCacheImport.indexKey) == nil)
    #expect(store.loadData(forKey: LegacyNavigationCacheImport.keyPrefix + "local") == nil)
  }

  @Test("Transcripts not opened within the retention window age out")
  func oldTranscriptsAgeOut() async throws {
    let fixture = try ClientCacheFixture()
    defer { fixture.tearDown() }
    let cache = try fixture.makeCache()

    cache.recordOpenedTranscript(fixture.opened(1...3, cursor: 5, hasMore: false), chat: fixture.chat)
    await cache.flush()
    fixture.advance(by: ClientCacheLimits.standard.transcriptAge - 1)
    cache.trim()
    await cache.flush()
    #expect(try cache.transcripts.page(of: fixture.chat) != nil)

    fixture.advance(by: 2)
    cache.trim()
    await cache.flush()
    #expect(try cache.transcripts.page(of: fixture.chat) == nil)
  }

  @Test("Opened files beyond the size budget are deleted, least recently used first")
  func filesOverBudgetAreDeleted() async throws {
    let fixture = try ClientCacheFixture()
    defer { fixture.tearDown() }
    var limits = ClientCacheLimits.standard
    limits.fileBytes = 15
    let cache = try fixture.makeCache(limits: limits)
    let older = CachedFileKey(machineId: "local", fileId: "older")
    let newer = CachedFileKey(machineId: "local", fileId: "newer")

    cache.recordFile(Data(repeating: 1, count: 10), variant: .original, file: older)
    await cache.flush()
    fixture.advance(by: 60)
    cache.recordFile(Data(repeating: 2, count: 10), variant: .original, file: newer)
    cache.trim()
    await cache.flush()

    let olderName = AttachmentCacheTables.fileName(for: older, variant: .original)
    let newerName = AttachmentCacheTables.fileName(for: newer, variant: .original)
    #expect(try cache.attachments.fileName(of: older, variant: .original) == nil)
    #expect(cache.files.read(named: olderName) == nil)
    #expect(cache.files.read(named: newerName) == Data(repeating: 2, count: 10))
  }

  private static func deletion(table: String, id: String) throws -> ServerNavigationDelta.Deletion {
    try JSONDecoder().decode(
      ServerNavigationDelta.Deletion.self, from: Data(#"{"table":"\#(table)","id":"\#(id)"}"#.utf8))
  }

  private static func chat(_ title: String, project: Project) -> ChatSession {
    ChatSession(
      id: UUID(), projectId: project.id, serverId: "local", harnessId: "codex", title: title,
      createdAt: Date(timeIntervalSince1970: 1))
  }
}

private struct AttachmentTransport: ServerRequestTransport {
  let bytes: Data

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    (bytes, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
