import CodevisorClient

public struct LaunchUpgradeLog: Equatable, Sendable {
  public struct Entry: Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let completed: Int
    public let total: Int
    public let isFinished: Bool
  }

  public private(set) var entries: [Entry] = []

  public init() {}

  public mutating func note(_ progress: LocalDataUpgradeProgress?) {
    guard let progress else { return }

    let entry = Self.entry(for: progress)
    if let index = entries.firstIndex(where: { $0.id == entry.id }) {
      entries[index] = entry
    } else {
      entries = entries.map(Self.finished) + [entry]
    }
  }

  public func including(_ progress: LocalDataUpgradeProgress) -> LaunchUpgradeLog {
    var log = self
    log.note(progress)
    return log
  }

  public mutating func clear() {
    entries = []
  }

  private static func entry(for progress: LocalDataUpgradeProgress) -> Entry {
    Entry(
      id: progress.id,
      name: progress.name,
      completed: progress.completed,
      total: progress.total,
      isFinished: progress.state == "completed"
    )
  }

  private static func finished(_ entry: Entry) -> Entry {
    Entry(id: entry.id, name: entry.name, completed: entry.total, total: entry.total, isFinished: true)
  }
}
