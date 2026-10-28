import CodevisorTestSupport
import Foundation
import Observation
import Synchronization
import Testing

@testable import CodevisorCore

@MainActor
@Suite("ClientPreferences")
struct ClientPreferencesTests {
  private func makeDatabase() throws -> (ClientDatabase, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("client-preferences-\(UUID().uuidString)", isDirectory: true)
    let database = try ClientDatabase(url: directory.appendingPathComponent(ClientDatabase.fileName))
    try database.migrate()
    return (database, directory)
  }

  private func holdDatabaseLock(_ database: ClientDatabase) async -> DatabaseLockHolder {
    let holder = DatabaseLockHolder(database)
    await holder.held.wait()
    return holder
  }

  @Test("A change is readable at once and reaches SQLite without the caller waiting for it")
  func writesDoNotWaitForTheDatabase() async throws {
    let (database, directory) = try makeDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let preferences = ClientPreferences(database: database)
    preferences.set("light", forKey: "theme")
    preferences.set("left", forKey: "sidebar")
    PersistenceEncoding.drain()

    let holder = await holdDatabaseLock(database)
    preferences.set("dark", forKey: "theme")
    preferences.removeValue(forKey: "sidebar")
    #expect(preferences.value(forKey: "theme", default: "") == "dark")
    #expect(preferences.valueIfPresent(forKey: "sidebar", as: String.self) == nil)
    #expect(await holder.release())

    PersistenceEncoding.drain()
    #expect(try database.preference(forKey: "theme") == JSONEncoder().encode("dark"))
    #expect(try database.preference(forKey: "sidebar") == nil)
  }

  @Test("Clearing everything is ordered before later changes, in memory and in SQLite")
  func removeAllThenSet() throws {
    let (database, directory) = try makeDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    let preferences = ClientPreferences(database: database)
    preferences.set(1, forKey: "old")
    PersistenceEncoding.drain()

    preferences.removeAll()
    preferences.set(2, forKey: "new")
    #expect(preferences.valueIfPresent(forKey: "old", as: Int.self) == nil)
    #expect(preferences.value(forKey: "new", default: 0) == 2)

    PersistenceEncoding.drain()
    #expect(try database.allPreferences() == ["new": JSONEncoder().encode(2)])
  }

  @Test("Preloaded preferences answer every read without the database")
  func preloadedReadsDoNotWaitForTheDatabase() async throws {
    let (database, directory) = try makeDatabase()
    defer { try? FileManager.default.removeItem(at: directory) }
    try database.setPreference(JSONEncoder().encode(true), forKey: "stored")
    let preferences = ClientPreferences()
    preferences.configure(database: database, preferences: try database.allPreferences())

    let holder = await holdDatabaseLock(database)
    #expect(preferences.value(forKey: "stored", default: false))
    #expect(preferences.valueIfPresent(forKey: "missing", as: Bool.self) == nil)
    #expect(await holder.release())
  }

  @Test("A reader is invalidated by changes to the keys it read, not by other keys")
  func observationIsScopedToTheKeysRead() {
    let preferences = ClientPreferences()
    let modeReader = observeChanges { _ = preferences.value(forKey: "sidebar.mode", default: "code") }
    let groupingReader = observeChanges { _ = preferences.valueIfPresent(forKey: "sidebar.grouping", as: String.self) }

    preferences.set("chat", forKey: "sidebar.mode")

    #expect(modeReader.hasFired)
    #expect(!groupingReader.hasFired)
  }

  @Test("Clearing every preference invalidates readers of any key")
  func removeAllInvalidatesEveryReader() {
    let preferences = ClientPreferences()
    preferences.set("chat", forKey: "sidebar.mode")
    let reader = observeChanges { _ = preferences.value(forKey: "sidebar.mode", default: "code") }

    preferences.removeAll()

    #expect(reader.hasFired)
  }

  private func observeChanges(_ read: () -> Void) -> ObservedChange {
    let change = ObservedChange()
    withObservationTracking(read) { change.fire() }
    return change
  }
}

private final class ObservedChange: Sendable {
  private let fired = Mutex(false)

  var hasFired: Bool { fired.withLock { $0 } }

  func fire() {
    fired.withLock { $0 = true }
  }
}

private final class DatabaseLockHolder: @unchecked Sendable {
  let held = TestSignal()
  private let finished = TestSignal()
  private let releaseSignal = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var gaveUp = false

  init(_ database: ClientDatabase) {
    Thread.detachNewThread { [self] in
      database.lock.lock()
      held.signal()
      let result = releaseSignal.wait(timeout: .now() + .seconds(30))
      lock.withLock { gaveUp = result == .timedOut }
      database.lock.unlock()
      finished.signal()
    }
  }

  func release() async -> Bool {
    releaseSignal.signal()
    await finished.wait()
    return lock.withLock { !gaveUp }
  }
}
