import CodevisorTestSupport
import Foundation
import Testing
@testable import CodevisorCloud

@MainActor
struct CloudMachineKeyPinCacheTests {
  @Test("Concurrent preparations share one storage read")
  func concurrentPreparation() async throws {
    let entered = TestSignal()
    let release = TestSignal()
    let joined = TestSignal()
    let store = CountingCredentialStore(base: InMemoryCloudCredentialStore())
    let cache = CloudMachineKeyPinCache(store: store) {
      entered.signal()
      await release.wait()
      return try store.pinnedMachineKeys()
    }
    let first = Task { try await cache.prepare() }
    await entered.wait()
    let second = Task {
      joined.signal()
      try await cache.prepare()
    }
    await joined.wait()
    release.signal()
    try await first.value
    try await second.value
    #expect(store.pinCounts.reads == 1)
    #expect(cache.pins == [:])
  }

  @Test("Pin snapshots load once off the main thread, including empty stores")
  func loadsOnce() async throws {
    let store = CountingCredentialStore(base: InMemoryCloudCredentialStore())
    let cache = CloudMachineKeyPinCache(store: store)
    try await cache.prepare()
    try await cache.prepare()
    #expect(cache.pins == [:])
    #expect(store.pinCounts.reads == 1)
    #expect(store.pinCounts.mainThreadReads == 0)
    try cache.save(["machine": "key"])
    try await cache.prepare()
    #expect(cache.pins == ["machine": "key"])
    #expect(store.pinCounts.reads == 1)
  }

  @Test("Unreadable pins remain unavailable and a later preparation can retry")
  func readFailure() async throws {
    let memory = InMemoryCloudCredentialStore()
    try memory.savePinnedMachineKeys(["machine": "trusted"])
    let store = CountingCredentialStore(base: memory)
    store.pinReadError = CloudCredentialError(operation: "read", status: -1)
    let cache = CloudMachineKeyPinCache(store: store)
    await #expect(throws: CloudCredentialError.self) { try await cache.prepare() }
    #expect(cache.pins == nil)
    store.pinReadError = nil
    try await cache.prepare()
    #expect(cache.pins == ["machine": "trusted"])
    #expect(store.pinCounts.reads == 2)
  }

  @Test("Failed writes preserve the previously trusted snapshot")
  func writeFailure() async throws {
    let memory = InMemoryCloudCredentialStore()
    try memory.savePinnedMachineKeys(["machine": "trusted"])
    let store = CountingCredentialStore(base: memory)
    let cache = CloudMachineKeyPinCache(store: store)
    try await cache.prepare()
    store.pinWriteError = CloudCredentialError(operation: "write", status: -1)
    #expect(throws: CloudCredentialError.self) { try cache.save(["machine": "replacement"]) }
    #expect(cache.pins == ["machine": "trusted"])
    #expect(try memory.pinnedMachineKeys() == cache.pins)
  }

  @Test("A delayed read cannot restore pins after sign-out or a server change")
  func invalidationDuringRead() async {
    let entered = TestSignal()
    let release = TestSignal()
    let cache = CloudMachineKeyPinCache(store: InMemoryCloudCredentialStore()) {
      entered.signal()
      await release.wait()
      return ["old-machine": "old-key"]
    }
    let prepare = Task { try await cache.prepare() }
    await entered.wait()
    cache.invalidate()
    release.signal()
    await #expect(throws: CancellationError.self) { try await prepare.value }
    #expect(cache.pins == nil)
  }

  @Test("A delayed read cannot replace newer explicitly saved pins")
  func saveDuringRead() async throws {
    let entered = TestSignal()
    let release = TestSignal()
    let memory = InMemoryCloudCredentialStore()
    let cache = CloudMachineKeyPinCache(store: memory) {
      entered.signal()
      await release.wait()
      return ["machine": "old-key"]
    }
    let prepare = Task { try await cache.prepare() }
    await entered.wait()
    // Always release the fake storage read, including if saving throws.
    defer { release.signal() }
    try cache.save(["machine": "new-key"])
    release.signal()
    await #expect(throws: CancellationError.self) { try await prepare.value }
    #expect(cache.pins == ["machine": "new-key"])
    #expect(try memory.pinnedMachineKeys() == cache.pins)
  }
}
