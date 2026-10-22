#if canImport(AppKit)
  import Foundation
  import Synchronization

  public final class StaticTextCache: Sendable {
    public typealias Preparer = @Sendable (StaticTextRequest) async -> PreparedStaticText?

    public static let shared = StaticTextCache(byteBudget: 48 * 1_048_576)

    private struct Entry {
      let value: PreparedStaticText
      let cost: Int
      var lastUse: UInt64
    }

    private struct State {
      var entries: [StaticTextKey: Entry] = [:]
      var inFlight: [StaticTextKey: Task<PreparedStaticText?, Never>] = [:]
      var totalCost = 0
      var clock: UInt64 = 0
    }

    private let byteBudget: Int
    private let preparer: Preparer
    private let state = Mutex(State())

    public init(
      byteBudget: Int,
      preparer: @escaping Preparer = { await PreparedStaticText.prepare($0) }
    ) {
      self.byteBudget = byteBudget
      self.preparer = preparer
    }

    public func cached(_ key: StaticTextKey) -> PreparedStaticText? {
      state.withLock { state in
        guard var entry = state.entries[key] else { return nil }
        state.clock &+= 1
        entry.lastUse = state.clock
        state.entries[key] = entry
        return entry.value
      }
    }

    public func prepared(_ request: StaticTextRequest) async -> PreparedStaticText? {
      if let hit = cached(request.key) { return hit }
      return await startPreparing(request).value
    }

    public func waitUntilIdle() async {
      while let task = state.withLock({ $0.inFlight.values.first }) {
        _ = await task.value
      }
    }

    public var totalCost: Int { state.withLock { $0.totalCost } }

    public var count: Int { state.withLock { $0.entries.count } }

    @discardableResult
    public func startPreparing(_ request: StaticTextRequest) -> Task<PreparedStaticText?, Never> {
      state.withLock { state in
        if let entry = state.entries[request.key] { return Task { entry.value } }
        if let existing = state.inFlight[request.key] { return existing }
        let preparer = preparer
        let task = Task.detached(priority: .userInitiated) { [self] in
          let value = await preparer(request)
          finish(request.key, value: value)
          return value
        }
        state.inFlight[request.key] = task
        return task
      }
    }

    private func finish(_ key: StaticTextKey, value: PreparedStaticText?) {
      state.withLock { state in
        state.inFlight[key] = nil
        guard let value, state.entries[key] == nil else { return }
        state.clock &+= 1
        let entry = Entry(value: value, cost: value.byteCost, lastUse: state.clock)
        state.entries[key] = entry
        state.totalCost += entry.cost
        evict(&state, keeping: key)
      }
    }

    private func evict(_ state: inout State, keeping protected: StaticTextKey) {
      while state.totalCost > byteBudget, state.entries.count > 1 {
        guard
          let oldest = state.entries.filter({ $0.key != protected }).min(by: { $0.value.lastUse < $1.value.lastUse })
        else { return }
        state.totalCost -= oldest.value.cost
        state.entries[oldest.key] = nil
      }
    }
  }
#endif
