import Foundation
import Testing
@testable import CodevisorCoreMac

@MainActor
@Suite("AppInstanceLease")
struct AppInstanceLeaseTests {
  private let fileManager = FileManager.default

  private static let release = "com.851labs.HerdMan"
  private static let applications = URL(fileURLWithPath: "/Applications/Codevisor.app", isDirectory: true)
  private static let downloads = URL(fileURLWithPath: "/Users/someone/Downloads/Codevisor.app", isDirectory: true)

  @Test("A release build shares one lock between its copies; a development build locks each copy")
  func lockURLScope() {
    let support = URL(fileURLWithPath: "/tmp/codevisor-lease-tests", isDirectory: true)
    func lock(_ bundleURL: URL, isDevelopment: Bool, bundleIdentifier: String? = Self.release) -> URL {
      AppInstanceLease.defaultLockURL(
        for: .current(bundleIdentifier: bundleIdentifier, bundleURL: bundleURL, isDevelopment: isDevelopment),
        applicationSupportURL: support
      )
    }
    let trailingSlash = URL(fileURLWithPath: "/Applications/Codevisor.app/", isDirectory: true)

    #expect(lock(Self.applications, isDevelopment: false) == lock(Self.downloads, isDevelopment: false))
    #expect(lock(Self.applications, isDevelopment: true) == lock(trailingSlash, isDevelopment: true))
    #expect(lock(Self.applications, isDevelopment: true) != lock(Self.downloads, isDevelopment: true))
    #expect(lock(Self.applications, isDevelopment: true) != lock(Self.applications, isDevelopment: false))
    #expect(
      lock(Self.applications, isDevelopment: false, bundleIdentifier: nil)
        == lock(Self.applications, isDevelopment: true))
  }

  @Test("A release build treats any running copy of the app as itself, but not its helpers")
  func releaseScopeCoversEveryCopy() {
    let scope = AppInstanceLease.Scope.current(
      bundleIdentifier: Self.release, bundleURL: Self.applications, isDevelopment: false)
    let helper = Self.applications.appendingPathComponent("Contents/Frameworks/Codevisor Browser Helper.app")

    #expect(scope.coversEveryCopy)
    #expect(scope.includes(bundleIdentifier: Self.release, bundleURL: Self.applications))
    #expect(scope.includes(bundleIdentifier: Self.release, bundleURL: Self.downloads))
    #expect(!scope.includes(bundleIdentifier: "\(Self.release).chromium.helper", bundleURL: helper))
  }

  @Test("A development build treats only its own copy as itself")
  func developmentScopeCoversOneCopy() {
    let identifier = "com.851labs.Codevisor.Development.abc123"
    let scope = AppInstanceLease.Scope.current(
      bundleIdentifier: identifier, bundleURL: Self.applications, isDevelopment: true)

    #expect(!scope.coversEveryCopy)
    #expect(scope.includes(bundleIdentifier: identifier, bundleURL: Self.applications))
    #expect(!scope.includes(bundleIdentifier: identifier, bundleURL: Self.downloads))
    #expect(!scope.includes(bundleIdentifier: identifier, bundleURL: nil))
  }

  @Test("A copy that finishes exiting within the wait does not stop this launch")
  func waitsForAnExitingCopy() {
    var clock: TimeInterval = 100
    let exited = AppInstanceLease.exits({ clock < 102 }, within: 5, now: { clock }, sleep: { clock += $0 })

    #expect(exited)
    #expect(clock >= 102 && clock < 102.1)
  }

  @Test("A copy still running when the wait ends counts as the running app")
  func givesUpOnACopyThatKeepsRunning() {
    var clock: TimeInterval = 100
    let exited = AppInstanceLease.exits({ true }, within: 5, now: { clock }, sleep: { clock += $0 })

    #expect(!exited)
    #expect(clock >= 105 && clock < 105.1)
  }

  @Test("A copy that is already gone costs no wait")
  func doesNotWaitForACopyThatIsGone() {
    var sleeps = 0
    let exited = AppInstanceLease.exits({ false }, within: 5, now: { 100 }, sleep: { _ in sleeps += 1 })

    #expect(exited && sleeps == 0)
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
      timeout: 3600
    )
    do {
      owner = nil

      #expect(try AppInstanceLease.acquire(at: lockURL) == nil)
      try writeBundleVersion("101", to: bundleURL)
      await handoff?.waitForExit()
      let successor = try AppInstanceLease.acquire(at: lockURL)
      #expect(successor != nil)
    } catch {
      handoff?.cancel()
      await handoff?.waitForExit()
      throw error
    }
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
      timeout: 3600
    )
    let handoff = try #require(pendingHandoff)
    owner = nil
    handoff.cancel()

    await handoff.waitForExit()
    let successor = try AppInstanceLease.acquire(at: lockURL)
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

}
