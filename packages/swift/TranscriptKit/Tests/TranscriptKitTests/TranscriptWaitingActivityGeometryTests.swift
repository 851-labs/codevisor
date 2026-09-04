import CoreGraphics
import Foundation
import Testing
@testable import TranscriptKit

struct TranscriptWaitingActivityGeometryTests {
  private typealias Row = TranscriptPresentationRow

  private func activity(_ message: AssistantMessage, aggregate: Bool = false) -> Row {
    if aggregate {
      return Row(id: .active(message.id), content: .active(.assistant(message)), estimatedHeight: 32)
    }
    return TranscriptActiveRowProjection.rows(for: .assistant(message))[0]
  }

  private func document(prompt: UserMessage, activity: Row) -> [Row] {
    [
      Row(id: .message(UUID()), content: .error("history"), estimatedHeight: 1_200),
      Row(id: .message(prompt.id), content: .message(.user(prompt), waitingOnBackgroundTask: nil), estimatedHeight: 50),
      activity,
      Row(id: .bottomSpacer, content: .bottomSpacer(100), estimatedHeight: 100),
    ]
  }

  private func screenY(_ key: String, in layout: VirtualTranscriptLayout) throws -> CGFloat {
    let index = try #require(layout.indexByKey[key])
    let viewport = VirtualTranscriptViewport(contentHeight: layout.totalHeight, viewportHeight: 600)
    return layout.topOffsets[index] - viewport.offsetY(distanceFromBottom: 0)
  }

  @Test(arguments: [false, true])
  func identityAdoptionKeepsLandedTranscriptStationary(throughAggregate: Bool) throws {
    let prompt = UserMessage(text: "Continue")
    let turn = AssistantTurn(isGenerating: true, startedAt: Date(timeIntervalSince1970: 100))
    let local = AssistantMessage(turn: turn)
    let server = AssistantMessage(turn: turn)
    let localRow = activity(local)
    let serverRow = activity(server)
    var rows = document(prompt: prompt, activity: localRow)
    var ledger = TranscriptMeasurementLedger()
    ledger.setExact(15, for: localRow.layoutKey)
    let landed = TranscriptDocumentGeometry.layout(rows: rows, measurements: ledger, spacing: 20)
    let historyKey = rows[0].layoutKey
    let promptKey = rows[1].layoutKey

    // Cover both a deferred precise projection at flight completion and an
    // acknowledgment whose aggregate bridge arrives after the flight. The
    // bridge may itself be replaced before a native measurement callback.
    let replacements = throughAggregate ? [activity(server, aggregate: true), serverRow] : [serverRow]
    for replacement in replacements {
      var nextRows = rows
      nextRows[2] = replacement
      TranscriptRowSet.preserveWaitingActivityHeight(from: rows, to: nextRows, ledger: &ledger)
      let next = TranscriptDocumentGeometry.layout(rows: nextRows, measurements: ledger, spacing: 20)

      #expect(next.totalHeight == landed.totalHeight)
      #expect(try screenY(historyKey, in: next) == screenY(historyKey, in: landed))
      #expect(try screenY(promptKey, in: next) == screenY(promptKey, in: landed))
      #expect(ledger[replacement.layoutKey] == 15)
      rows = nextRows
    }

    // Committing the replacement's own measurement must not trigger the
    // second scroll correction seen in the recording.
    let heightChanged = ledger.commit(15, for: serverRow.layoutKey)
    #expect(!heightChanged)
  }

  @Test func aggregateProjectionPreservesHeightBeforeSendStarts() {
    let prompt = UserMessage(text: "Continue")
    let message = AssistantMessage(turn: AssistantTurn(isGenerating: true))
    let aggregate = activity(message, aggregate: true)
    let precise = activity(message)
    var ledger = TranscriptMeasurementLedger()
    ledger.setExact(15, for: aggregate.layoutKey)

    TranscriptRowSet.preserveWaitingActivityHeight(
      from: document(prompt: prompt, activity: aggregate),
      to: document(prompt: prompt, activity: precise),
      ledger: &ledger
    )

    #expect(ledger[precise.layoutKey] == 15)
    #expect(!ledger.isStale(precise.layoutKey))
  }

  @Test func differentPromptOrChangedContentRequiresFreshGeometry() {
    let prompt = UserMessage(text: "Continue")
    let turn = AssistantTurn(isGenerating: true)
    let localRow = activity(AssistantMessage(turn: turn))
    let oldRows = document(prompt: prompt, activity: localRow)
    var thinking = turn
    thinking.isThinking = true
    var retry = turn
    retry.retryStatus = RetryStatus(attempt: 1, of: 3, message: "Retrying a longer status message")
    var nextTurn = turn
    nextTurn.startedAt = Date(timeIntervalSince1970: 200)

    let candidates = [
      document(prompt: UserMessage(text: "Next prompt"), activity: activity(AssistantMessage(turn: turn))),
      document(prompt: prompt, activity: activity(AssistantMessage(turn: thinking))),
      document(prompt: prompt, activity: activity(AssistantMessage(turn: retry))),
      document(prompt: prompt, activity: activity(AssistantMessage(turn: nextTurn))),
    ]
    for candidate in candidates {
      var ledger = TranscriptMeasurementLedger()
      ledger.setExact(15, for: localRow.layoutKey)
      TranscriptRowSet.preserveWaitingActivityHeight(from: oldRows, to: candidate, ledger: &ledger)
      #expect(ledger[candidate[2].layoutKey] == nil)
    }
  }

  @Test func staleOrMissingMeasurementsCannotBecomeExactAgain() {
    let prompt = UserMessage(text: "Continue")
    let turn = AssistantTurn(isGenerating: true)
    let old = activity(AssistantMessage(turn: turn))
    let new = activity(AssistantMessage(turn: turn))
    let oldRows = document(prompt: prompt, activity: old)
    let newRows = document(prompt: prompt, activity: new)
    var ledger = TranscriptMeasurementLedger()

    TranscriptRowSet.preserveWaitingActivityHeight(from: oldRows, to: newRows, ledger: &ledger)
    #expect(ledger[new.layoutKey] == nil)

    // A width/typography invalidation makes the old height provisional.
    ledger.setProvisional(15, for: old.layoutKey)
    TranscriptRowSet.preserveWaitingActivityHeight(from: oldRows, to: newRows, ledger: &ledger)
    #expect(ledger[new.layoutKey] == nil)

    ledger.setExact(15, for: old.layoutKey)
    ledger.setExact(19, for: new.layoutKey)
    TranscriptRowSet.preserveWaitingActivityHeight(from: oldRows, to: newRows, ledger: &ledger)
    #expect(ledger[new.layoutKey] == 19)
  }
}
