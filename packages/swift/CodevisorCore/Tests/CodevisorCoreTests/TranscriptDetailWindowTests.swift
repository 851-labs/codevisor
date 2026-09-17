import CodevisorClient
import Testing
@testable import CodevisorCore

struct TranscriptDetailWindowTests {
  private func page(_ index: Int, revision: Int = 1) -> ServerTranscriptItemDetails {
    .init(
      itemId: "turn", revision: revision, eventCursor: revision,
      entries: [.init(key: "tool:\(index)", position: index, revision: revision, payload: .object([:]))],
      nextAfter: "after:\(index)", previousBefore: "before:\(index)")
  }

  @Test func scrollingBothDirectionsKeepsOverlapAndBoundsMemory() {
    var window = TranscriptDetailWindow()
    for index in 0..<10 {
      let resident = window.install(page(index), previous: false)
      #expect(resident.entries.map(\.position) == Array(max(0, index - 2)...index))
      #expect(window.pages.count <= 3)
    }
    for index in (0...6).reversed() {
      let resident = window.install(page(index), previous: true)
      #expect(resident.entries.map(\.position) == Array(index...(index + 2)))
      #expect(resident.previousBefore == "before:\(index)")
      #expect(resident.nextAfter == "after:\(index + 2)")
      #expect(window.pages.count == 3)
    }
  }

  @Test func overlappingParentHeadersKeepTheirNewestRevision() {
    var window = TranscriptDetailWindow()
    _ = window.install(page(1, revision: 5), previous: false)
    let resident = window.install(page(1, revision: 2), previous: true)
    #expect(resident.entries.count == 1)
    #expect(resident.entries.first?.revision == 5)
    #expect(resident.eventCursor == 2)
  }
}
