import Foundation
import Testing
@testable import CodevisorCoreMac

@MainActor
@Suite("AppInstanceLease")
struct AppInstanceLeaseTests {
  private let fileManager = FileManager.default

  @Test("Scopes the stable lock name to the resolved bundle path")
  func lockURLScope() {
    let support = URL(fileURLWithPath: "/tmp/codevisor-lease-tests", isDirectory: true)
    let first = AppInstanceLease.defaultLockURL(
      for: URL(fileURLWithPath: "/Applications/Codevisor.app", isDirectory: true),
      applicationSupportURL: support
    )
    let same = AppInstanceLease.defaultLockURL(
      for: URL(fileURLWithPath: "/Applications/Codevisor.app/", isDirectory: true),
      applicationSupportURL: support
    )
    let other = AppInstanceLease.defaultLockURL(
      for: URL(fileURLWithPath: "/tmp/Codevisor.app", isDirectory: true),
      applicationSupportURL: support
    )

    #expect(first == same)
    #expect(first != other)
  }

  @Test("Rejects a second owner and releases on deinit")
  func exclusiveOwnership() throws {
    let fixture = makeFixture()
    defer { try? fileManager.removeItem(at: fixture) }
    let lockURL = fixture.appendingPathComponent("instance.lock")

    var owner = try AppInstanceLease.acquire(at: lockURL)
    #expect(owner != nil)
    #expect(try AppInstanceLease.acquire(at: lockURL) == nil)

    owner = nil
    owner = try AppInstanceLease.acquire(at: lockURL)
    #expect(owner != nil)
  }

  @Test("Handoff owns the lock until the target bundle is installed")
  func updateHandoff() async throws {
    let fixture = makeFixture()
    defer { try? fileManager.removeItem(at: fixture) }
    let bundleURL = fixture.appendingPathComponent("Codevisor.app", isDirectory: true)
    let lockURL = fixture.appendingPathComponent("instance.lock")
    try writeBundleVersion("100", to: bundleURL)

    var owner = try AppInstanceLease.acquire(at: lockURL)
    #expect(owner != nil)
    let handoff = try owner?.beginUpdateHandoff(
      targetBundleVersion: "101",
      applicationBundleURL: bundleURL,
      timeout: 5
    )
    owner = nil

    #expect(try AppInstanceLease.acquire(at: lockURL) == nil)
    try writeBundleVersion("101", to: bundleURL)
    let successor = try await acquireEventually(at: lockURL)
    #expect(successor != nil)
    #expect(handoff?.isRunning == false)
  }

  @Test("Cancelling an aborted update releases the inherited lock")
  func cancelHandoff() async throws {
    let fixture = makeFixture()
    defer { try? fileManager.removeItem(at: fixture) }
    let bundleURL = fixture.appendingPathComponent("Codevisor.app", isDirectory: true)
    let lockURL = fixture.appendingPathComponent("instance.lock")
    try writeBundleVersion("100", to: bundleURL)

    var owner = try AppInstanceLease.acquire(at: lockURL)
    #expect(owner != nil)
    let pendingHandoff = try owner?.beginUpdateHandoff(
      targetBundleVersion: "101",
      applicationBundleURL: bundleURL,
      timeout: 5
    )
    let handoff = try #require(pendingHandoff)
    owner = nil
    handoff.cancel()

    let successor = try await acquireEventually(at: lockURL)
    #expect(successor != nil)
  }

  private func makeFixture() -> URL {
    fileManager.temporaryDirectory
      .appendingPathComponent("app-instance-lease-\(UUID().uuidString)", isDirectory: true)
  }

  private func writeBundleVersion(_ version: String, to bundleURL: URL) throws {
    let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
    try fileManager.createDirectory(at: contents, withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["CFBundleVersion": version],
      format: .binary,
      options: 0
    )
    try data.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
  }

  private func acquireEventually(at lockURL: URL) async throws -> AppInstanceLease? {
    for _ in 0..<100 {
      if let lease = try AppInstanceLease.acquire(at: lockURL) {
        return lease
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    return nil
  }
}
