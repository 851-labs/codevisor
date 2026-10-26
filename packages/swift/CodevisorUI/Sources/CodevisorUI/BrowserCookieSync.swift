import CodevisorClient
import Foundation

@MainActor
public final class BrowserCookieSync {
  public static let visiblePollInterval: Duration = .seconds(2)
  public static let hiddenPollInterval: Duration = .seconds(30)

  private typealias Cookies = [String: BrowserCookie]
  private let client: any BrowserStateClienting
  private let read: @MainActor () async throws -> [BrowserCookie]
  private let apply: @MainActor (BrowserCookie?, BrowserCookie?) async throws -> Void
  private var baseline: Cookies?
  private var revisions: [String: Int] = [:]
  private var lastRead: (cookies: [BrowserCookie], keyed: Cookies)?
  private var pending: Task<Bool, Error>?
  private var timer: Task<Void, Never>?
  private var pollInterval = BrowserCookieSync.visiblePollInterval
  public private(set) var generation = 0
  public private(set) var lastError: String?

  public init(
    client: any BrowserStateClienting,
    read: @escaping @MainActor () async throws -> [BrowserCookie],
    apply: @escaping @MainActor (BrowserCookie?, BrowserCookie?) async throws -> Void
  ) { self.client = client; self.read = read; self.apply = apply }

  public func start() {
    guard timer == nil else { return }
    timer = poll(immediately: true)
  }
  public func stop() { timer?.cancel(); timer = nil }
  public var isCurrent: Bool { baseline != nil && timer != nil }

  public func setVisible(_ visible: Bool) {
    let interval = visible ? Self.visiblePollInterval : Self.hiddenPollInterval
    guard interval != pollInterval else { return }
    pollInterval = interval
    guard timer != nil else { return }
    timer?.cancel()
    timer = poll(immediately: false)
  }

  private func poll(immediately: Bool) -> Task<Void, Never> {
    let interval = pollInterval
    return Task { [weak self] in
      if !immediately { do { try await Task.sleep(for: interval) } catch { return } }
      while !Task.isCancelled {
        _ = try? await self?.synchronize()
        do { try await Task.sleep(for: interval) } catch { break }
      }
    }
  }

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

  private func readLocal() async throws -> Cookies {
    let cookies = try await read()
    let keyed = await Self.keyed(cookies, reusing: lastRead)
    lastRead = (cookies, keyed)
    return keyed
  }

  private func exchange() async throws -> Bool {
    let local = try await readLocal()
    if baseline == nil {
      let snapshot = try await client.exchangeBrowserCookies([])
      revisions = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.key, $0.revision) })
      let now = try await readLocal()
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
      if !appliedKeys.isEmpty {
        let normalized = try await readLocal()
        for key in appliedKeys { baseline?[key] = normalized[key] }
      }
      return try await exchange()
    }
    let baseline = self.baseline ?? [:]
    let mutations = await Self.mutations(local: local, baseline: baseline, revisions: revisions)
    let snapshot = try await client.exchangeBrowserCookies(mutations)
    let plan = await Self.plan(snapshot.entries, local: local, baseline: baseline, revisions: revisions)
    var nextBaseline = local
    var changed = false
    var appliedKeys = Set<String>()
    if !plan.candidates.isEmpty {
      let now = try await readLocal()
      for index in plan.candidates {
        let entry = snapshot.entries[index]
        guard now[entry.key] == local[entry.key] else { continue }
        if now[entry.key] != entry.cookie {
          do { try await apply(entry.cookie, now[entry.key]) } catch {
            for earlier in snapshot.entries[...index] { revisions[earlier.key] = earlier.revision }
            throw error
          }
          changed = true
          appliedKeys.insert(entry.key)
        }
        nextBaseline[entry.key] = entry.cookie
      }
    }
    revisions = plan.revisions
    if !appliedKeys.isEmpty {
      let applied = try await readLocal()
      for key in appliedKeys { nextBaseline[key] = applied[key] }
    }
    self.baseline = nextBaseline
    if changed { generation += 1 }
    return changed
  }

  @concurrent
  private nonisolated static func keyed(
    _ cookies: [BrowserCookie], reusing previous: (cookies: [BrowserCookie], keyed: Cookies)?
  ) async -> Cookies {
    if let previous, previous.cookies == cookies { return previous.keyed }
    return Dictionary(cookies.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
  }

  @concurrent
  private nonisolated static func mutations(
    local: Cookies, baseline: Cookies, revisions: [String: Int]
  ) async -> [BrowserCookieMutation] {
    Set(local.keys).union(baseline.keys).compactMap { key in
      guard local[key] != baseline[key] else { return nil }
      return BrowserCookieMutation(key: key, expectedRevision: revisions[key] ?? 0, cookie: local[key])
    }
  }

  @concurrent
  private nonisolated static func plan(
    _ entries: [BrowserCookieEntry], local: Cookies, baseline: Cookies, revisions: [String: Int]
  ) async -> (revisions: [String: Int], candidates: [Int]) {
    var revisions = revisions
    var candidates: [Int] = []
    for (index, entry) in entries.enumerated() {
      let serverChanged = revisions[entry.key] != entry.revision
      revisions[entry.key] = entry.revision
      if serverChanged || local[entry.key] != baseline[entry.key] { candidates.append(index) }
    }
    return (revisions, candidates)
  }
}
