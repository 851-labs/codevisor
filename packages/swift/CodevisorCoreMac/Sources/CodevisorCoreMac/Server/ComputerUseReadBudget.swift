import ApplicationServices
import Darwin
import Foundation

struct ComputerUseReadBudget: Sendable {
  static let unlimited = ComputerUseReadBudget(budgetMilliseconds: nil)

  let deadline: TimeInterval?
  private let now: @Sendable () -> TimeInterval
  private let clientDisconnected: @Sendable () -> Bool

  init(
    budgetMilliseconds: Double?,
    clientDisconnected: @escaping @Sendable () -> Bool = { false },
    now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) {
    deadline = budgetMilliseconds.map { now() + max(0, $0) / 1_000 }
    self.now = now
    self.clientDisconnected = clientDisconnected
  }

  var isExhausted: Bool {
    if let deadline, now() >= deadline { return true }
    return clientDisconnected()
  }
}

func computerUseClientDisconnected(_ descriptor: Int32) -> Bool {
  var byte: UInt8 = 0
  let count = recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
  if count > 0 { return false }
  if count == 0 { return true }
  return errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR
}

struct ComputerUseSnapshotLimits {
  static let observationNodes = 2_000
  static let observationRecords = 1_200
  static let rowsPerList = 50

  var remainingNodes: Int
  let maxRecords: Int
  let rowsPerList: Int
  let budget: ComputerUseReadBudget
  private(set) var stoppedForTime = false
  private(set) var reachedSizeLimit = false
  var openMenu: AXUIElement?
  var sawBusyIndicator = false

  init(
    budget: ComputerUseReadBudget,
    nodes: Int = observationNodes,
    records: Int = observationRecords,
    rowsPerList: Int = rowsPerList
  ) {
    remainingNodes = nodes
    maxRecords = records
    self.rowsPerList = rowsPerList
    self.budget = budget
  }

  mutating func admit(recordCount: Int) -> Bool {
    if stoppedForTime || reachedSizeLimit { return false }
    if remainingNodes <= 0 || recordCount >= maxRecords {
      reachedSizeLimit = true
      return false
    }
    if budget.isExhausted {
      stoppedForTime = true
      return false
    }
    remainingNodes -= 1
    return true
  }

  var truncationNote: String? {
    let remedy = "Use find to search the rest, or pass element_index to read one part of the window."
    if stoppedForTime { return "Observation stopped early to finish within the execute call's timeout. \(remedy)" }
    if reachedSizeLimit { return "Observation truncated at \(maxRecords) elements. \(remedy)" }
    return nil
  }
}

func computerUseCarriedRecords<Record>(_ records: [String: Record], limit: Int = 2_000) -> [String: Record] {
  guard records.count > limit else { return records }
  let newest = records.keys.sorted { (Int($0) ?? -1) > (Int($1) ?? -1) }.prefix(limit)
  return records.filter { newest.contains($0.key) }
}

func computerUseShownRows(total: Int, visible: [Int], limit: Int) -> Range<Int> {
  guard total > 0, limit > 0 else { return 0..<0 }
  let lower = min(visible.min() ?? 0, total - 1)
  let upper = min(total, visible.max().map { $0 + 1 } ?? total, lower + limit)
  return lower..<max(lower, upper)
}

func computerUseHiddenRowsNote(shown: Range<Int>, total: Int, noun: String = "rows") -> String? {
  let hidden = total - shown.count
  guard hidden > 0 else { return nil }
  let range = shown.isEmpty ? "none" : "\(shown.lowerBound + 1)–\(shown.upperBound)"
  return
    "… \(hidden) more \(noun) not shown (showing \(range) of \(total)). Scroll, or use find to search every \(noun.dropLast())."
}
