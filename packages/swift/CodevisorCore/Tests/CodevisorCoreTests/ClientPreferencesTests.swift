import CodevisorTestSupport
import Foundation
import Testing

@testable import CodevisorCore

/// The persistence queue holds the database lock while it writes large
/// navigation snapshots; preferences are read and written from views on the
/// main thread and must never wait for it.
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

  /// Holds the database's lock on another thread, as a long write on the
  /// persistence queue does. `release()` returns false when the main thread
  /// was stuck behind the lock until the holder's deadlock guard gave up.
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
    // Before writes went through the persistence queue, each of these
    // blocked on the lock held above.
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
    // The cleared row is still in SQLite until the batch lands; reads must
    // not resurrect it.
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
      // Deadlock guard only: a caller that never blocks releases first.
      let result = releaseSignal.wait(timeout: .now() + .seconds(30))
      lock.withLock { gaveUp = result == .timedOut }
      database.lock.unlock()
      finished.signal()
    }
  }

  /// Releases the lock; true when the caller got here before the guard.
  func release() async -> Bool {
    releaseSignal.signal()
    await finished.wait()
    return lock.withLock { !gaveUp }
  }
}
