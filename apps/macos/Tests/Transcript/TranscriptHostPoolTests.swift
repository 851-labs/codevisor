import AppKit
import Testing
@testable import TranscriptSurface

@Suite("Transcript host lifetime")
@MainActor
struct TranscriptHostPoolTests {
  @Test("Excess hosts release incrementally while warm hosts remain reusable")
  func boundedRetirement() {
    _ = NSApplication.shared
    let pool = TranscriptHostPool()
    let references: (first: () -> Bool, second: () -> Bool) = autoreleasepool {
      let first = TranscriptRowHost(frame: .zero)
      let second = TranscriptRowHost(frame: .zero)
      pool.retire(first)
      pool.retire(second)
      for _ in 0..<8 { pool.retire(TranscriptRowHost(frame: .zero)) }
      return ({ [weak first] in first != nil }, { [weak second] in second != nil })
    }

    autoreleasepool { pool.drainRetiringHosts(limit: 8) }
    #expect(references.first() && references.second())
    autoreleasepool { pool.drainRetiringHosts(limit: 1) }
    #expect(references.first() && !references.second())
    autoreleasepool { pool.drainRetiringHosts(limit: 1) }
    #expect(!references.first() && !pool.hasRetiringHosts)

    var reusedCount = 0
    while pool.takeHostedRow() != nil { reusedCount += 1 }
    #expect(reusedCount == 8)
  }
}
