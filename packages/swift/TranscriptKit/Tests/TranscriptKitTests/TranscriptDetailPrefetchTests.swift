import Foundation
import Testing
@testable import TranscriptKit

struct TranscriptDetailPrefetchTests {
  @Test func pageInstallationCannotReverseScrollingOrRepeatARequest() {
    var policy = TranscriptDetailPrefetchPolicy()
    let older = TranscriptDetailPageRequest(itemID: "turn", cursor: "older", previous: true)
    let newer = TranscriptDetailPageRequest(itemID: "turn", cursor: "newer", previous: false)
    #expect(!policy.requestIfNeeded(older, distance: 0, threshold: 600) { true })
    policy.observeUserScroll(delta: -20)
    #expect(policy.requestIfNeeded(older, distance: 200, threshold: 600) { true })
    #expect(!policy.requestIfNeeded(older, distance: 200, threshold: 600) { true })
    let nextOlder = TranscriptDetailPageRequest(itemID: "turn", cursor: "even older", previous: true)
    #expect(!policy.requestIfNeeded(nextOlder, distance: 0, threshold: 600) { true })
    #expect(!policy.requestIfNeeded(newer, distance: 0, threshold: 600) { true })
    policy.observeUserScroll(delta: 20)
    #expect(!policy.requestIfNeeded(newer, distance: 900, threshold: 600) { true })
    #expect(!policy.requestIfNeeded(newer, distance: 0, threshold: 600) { false })
    #expect(policy.requestIfNeeded(newer, distance: 0, threshold: 600) { true })
    #expect(!policy.requestIfNeeded(newer, distance: 900, threshold: 600) { true })
    policy.observeUserScroll(delta: 20)
    #expect(policy.requestIfNeeded(newer, distance: 0, threshold: 600) { true })
  }

  @Test func hydratedWorkProjectsAutomaticPageEdgesInReadingOrder() {
    var turn = AssistantTurn(
      entries: [.text(id: "work", markdown: "Earlier activity"), .text(id: "answer", markdown: "Done")],
      deferredDetailItemId: "turn", hasDeferredWorkedDetails: true)
    turn.hasHydratedWorkedDetails = true
    turn.detailPreviousBefore = "older"
    turn.detailNextAfter = "newer"
    let rows = TranscriptActiveRowProjection.rows(for: .assistant(.init(turn: turn)))
    let requests = rows.compactMap { row -> TranscriptDetailPageRequest? in
      if case let .workedDetailPage(request) = row.content { return request }
      return nil
    }
    #expect(requests.map(\.cursor) == ["older", "newer"])
    #expect(requests.map(\.previous) == [true, false])
    #expect(
      rows.filter { if case .workedDetailPage = $0.content { true } else { false } }
        .allSatisfy { $0.workedSection?.role == .content })
  }
}
