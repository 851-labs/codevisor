import CodevisorClient
import Foundation

/// One coordinator per machine/profile, shared by every pane using that store.
@MainActor
public final class BrowserCookieSync {
  private let client: any BrowserStateClienting
  private let read: @MainActor () async throws -> [BrowserCookie]
  private let apply: @MainActor (BrowserCookie?, BrowserCookie?) async throws -> Void
  private var baseline: [String: BrowserCookie]?
  private var revisions: [String: Int] = [:]
  private var pending: Task<Bool, Error>?
  private var timer: Task<Void, Never>?
  public private(set) var generation = 0
  public private(set) var lastError: String?

  public init(
    client: any BrowserStateClienting,
    read: @escaping @MainActor () async throws -> [BrowserCookie],
    apply: @escaping @MainActor (BrowserCookie?, BrowserCookie?) async throws -> Void
  ) { self.client = client; self.read = read; self.apply = apply }

  public func start() {
    guard timer == nil else { return }
    timer = Task { [weak self] in
      while !Task.isCancelled {
        _ = try? await self?.synchronize()
        do { try await Task.sleep(for: .seconds(2)) } catch { break }
      }
    }
  }
  public func stop() { timer?.cancel(); timer = nil }

  @discardableResult
  public func synchronize() async throws -> Bool {
    if let pending { return try await pending.value }
    let task = Task { try await self.exchange() }
    pending = task
    defer { pending = nil }
    do { let changed = try await task.value; lastError = nil; return changed } catch {
      lastError = error.localizedDescription; throw error
    }
  }

  private func exchange() async throws -> Bool {
    let local = Dictionary((try await read()).map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
    // Bootstrap pulls tombstones first. Only previously unknown cookies can be adopted.
    if baseline == nil {
      let snapshot = try await client.exchangeBrowserCookies([])
      revisions = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.key, $0.revision) })
      let now = Dictionary((try await read()).map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
      baseline = [:]
      var appliedKeys = Set<String>()
      for entry in snapshot.entries {
        guard now[entry.key] == local[entry.key] else {
          baseline?[entry.key] = local[entry.key]
          continue
        }
        if now[entry.key] != entry.cookie {
          try await apply(entry.cookie, now[entry.key])
          appliedKeys.insert(entry.key)
          generation += 1
        }
        baseline?[entry.key] = entry.cookie
      }
      let normalized = Dictionary((try await read()).map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
      for key in appliedKeys { baseline?[key] = normalized[key] }
      // Unknown cookies and page changes during bootstrap are published next.
      return try await exchange()
    }
    let keys = Set(local.keys).union(baseline!.keys)
    let mutations = keys.compactMap { key -> BrowserCookieMutation? in
      guard local[key] != baseline?[key] else { return nil }
      return BrowserCookieMutation(key: key, expectedRevision: revisions[key] ?? 0, cookie: local[key])
    }
    let snapshot = try await client.exchangeBrowserCookies(mutations)
    let now = Dictionary((try await read()).map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
    var nextBaseline = local
    var changed = false
    var appliedKeys = Set<String>()
    for entry in snapshot.entries {
      let serverChanged = revisions[entry.key] != entry.revision
      revisions[entry.key] = entry.revision
      // The engine may round expiry or normalize SameSite on import. An
      // unchanged server revision already corresponds to our normalized
      // baseline; reapplying it would invalidate every cached tab on each poll.
      guard serverChanged || local[entry.key] != baseline?[entry.key] else { continue }
      // A page may set another cookie while the server is replying. Publish that
      // change on the next exchange instead of overwriting it with this reply.
      guard now[entry.key] == local[entry.key] else { continue }
      if now[entry.key] != entry.cookie {
        try await apply(entry.cookie, now[entry.key])
        changed = true
        appliedKeys.insert(entry.key)
      }
      nextBaseline[entry.key] = entry.cookie
    }
    // Engines normalize expiry and SameSite; remember their representation.
    let applied = Dictionary((try await read()).map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
    for key in appliedKeys {
      nextBaseline[key] = applied[key]
    }
    baseline = nextBaseline
    if changed { generation += 1 }
    return changed
  }
}
