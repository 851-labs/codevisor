import Darwin
import Foundation
import Synchronization
import Testing
@testable import CodevisorCoreMac

@Suite("Computer Use read budgets")
struct ComputerUseReadBudgetTests {
  private final class ManualUptime: Sendable {
    private let seconds = Mutex<TimeInterval>(100)
    func now() -> TimeInterval { seconds.withLock { $0 } }
    func advance(by interval: TimeInterval) { seconds.withLock { $0 += interval } }
  }

  @Test("A read stops at the execute deadline and says it stopped for time")
  func deadline() {
    let uptime = ManualUptime()
    var limits = ComputerUseSnapshotLimits(
      budget: ComputerUseReadBudget(budgetMilliseconds: 1_000, now: { uptime.now() }))
    let atStart = limits.admit(recordCount: 0)
    #expect(atStart)
    uptime.advance(by: 0.75)
    let beforeDeadline = limits.admit(recordCount: 0)
    #expect(beforeDeadline)
    uptime.advance(by: 0.25)
    let atDeadline = limits.admit(recordCount: 0)
    #expect(!atDeadline)
    #expect(limits.stoppedForTime)
    #expect(
      limits.truncationNote?.hasPrefix("Observation stopped early to finish within the execute call's timeout.") == true
    )
    #expect(limits.truncationNote?.contains("timed out") == false)
  }

  @Test("A read without a deadline stops only at its size limits")
  func sizeLimits() {
    var nodes = ComputerUseSnapshotLimits(budget: .unlimited, nodes: 2, records: 10)
    let first = nodes.admit(recordCount: 0)
    let second = nodes.admit(recordCount: 0)
    #expect(first && second)
    let third = nodes.admit(recordCount: 0)
    #expect(!third)
    #expect(nodes.reachedSizeLimit && !nodes.stoppedForTime)
    #expect(nodes.truncationNote?.hasPrefix("Observation truncated at 10 elements. Use find") == true)

    var records = ComputerUseSnapshotLimits(budget: .unlimited, nodes: 10, records: 3)
    let overRecordLimit = records.admit(recordCount: 3)
    #expect(!overRecordLimit)
    #expect(records.reachedSizeLimit)
  }

  @Test("A request is cancelled once its client closes the connection, not while requests are queued")
  func clientDisconnect() throws {
    var pair: [Int32] = [0, 0]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    defer { Darwin.close(pair[0]) }
    let budget = ComputerUseReadBudget(
      budgetMilliseconds: nil, clientDisconnected: { [server = pair[0]] in computerUseClientDisconnected(server) })
    #expect(!budget.isExhausted)
    var byte: UInt8 = 1
    #expect(write(pair[1], &byte, 1) == 1)
    Darwin.close(pair[1])
    #expect(!budget.isExhausted)
    #expect(recv(pair[0], &byte, 1, 0) == 1)
    #expect(budget.isExhausted)
  }

  @Test("Long lists keep the visible rows, capped, and say how many rows were left out")
  func rowWindow() {
    #expect(computerUseShownRows(total: 200, visible: [40, 41, 42, 60], limit: 50) == 40..<61)
    #expect(computerUseShownRows(total: 200, visible: Array(10..<150), limit: 50) == 10..<60)
    #expect(computerUseShownRows(total: 200, visible: [], limit: 50) == 0..<50)
    #expect(computerUseShownRows(total: 30, visible: [], limit: 50) == 0..<30)
    #expect(computerUseShownRows(total: 0, visible: [], limit: 50).isEmpty)
    #expect(
      computerUseHiddenRowsNote(shown: 40..<61, total: 200)
        == "… 179 more rows not shown (showing 41–61 of 200). Scroll, or use find to search every row.")
    #expect(computerUseHiddenRowsNote(shown: 0..<30, total: 30) == nil)
    #expect(
      computerUseHiddenRowsNote(shown: 0..<50, total: 300, noun: "items")
        == "… 250 more items not shown (showing 1–50 of 300). Scroll, or use find to search every item.")
  }

  @Test("Earlier element indexes stay usable after a later observation, keeping the newest when there are many")
  func carriedRecords() {
    let few = ["3": "c", "10": "j"]
    #expect(computerUseCarriedRecords(few) == few)
    let many = Dictionary(uniqueKeysWithValues: (1...5).map { (String($0), $0) })
    #expect(Set(computerUseCarriedRecords(many, limit: 2).keys) == ["4", "5"])
  }

  @Test("find matches names and values without case or accents, and filters by role or subrole")
  func findMatching() {
    let song = ["Hedwig’s Theme", "", "", "", ""]
    #expect(computerUseFindMatches(query: "hedwig", role: nil, role: "AXStaticText", subrole: nil, texts: song))
    #expect(computerUseFindMatches(query: "Cafe", role: nil, role: "AXButton", subrole: nil, texts: ["Café"]))
    #expect(!computerUseFindMatches(query: "imperial", role: nil, role: "AXStaticText", subrole: nil, texts: song))
    #expect(computerUseFindMatches(query: nil, role: "AXRow", role: "AXRow", subrole: nil, texts: []))
    #expect(!computerUseFindMatches(query: "hedwig", role: "AXButton", role: "AXStaticText", subrole: nil, texts: song))
    #expect(
      computerUseFindMatches(
        query: nil, role: "AXSearchField", role: "AXTextField", subrole: "AXSearchField", texts: []))
  }
}
