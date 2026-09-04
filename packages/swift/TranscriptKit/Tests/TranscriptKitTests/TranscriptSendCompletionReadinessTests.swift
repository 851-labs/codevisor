import Foundation
import Testing
@testable import TranscriptKit

@MainActor
struct TranscriptSendCompletionReadinessTests {
  private typealias Row = TranscriptPresentationRow

  private final class Host: TranscriptPresentableRowHost {
    var isPresentationReady = false
    var isAttachmentGeometryReady = true
  }

  @Test func revealWaitsForReplacementLayoutAndMeasurementCommit() {
    let user = UserMessage(text: "Continue")
    let userRow = Row(
      id: .message(user.id), content: .message(.user(user), waitingOnBackgroundTask: nil), estimatedHeight: 50)
    let turn = AssistantTurn(isGenerating: true)
    let localRow = TranscriptActiveRowProjection.rows(for: .assistant(AssistantMessage(turn: turn)))[0]
    let serverRow = TranscriptActiveRowProjection.rows(for: .assistant(AssistantMessage(turn: turn)))[0]
    let spacer = Row(id: .bottomSpacer, content: .bottomSpacer(100), estimatedHeight: 100)
    let previous = [userRow, localRow, spacer]
    let replacement = [userRow, serverRow, spacer]
    var measurements = TranscriptMeasurementLedger()
    measurements.setExact(50, for: userRow.layoutKey)
    measurements.setExact(15, for: localRow.layoutKey)
    TranscriptRowSet.preserveWaitingActivityHeight(from: previous, to: replacement, ledger: &measurements)

    let userHost = Host()
    userHost.isPresentationReady = true
    let assistantHost = Host()
    let hosts = [userRow.layoutKey: userHost, serverRow.layoutKey: assistantHost]
    var pending: Set<String> = []
    func ready(_ rows: [Row]? = nil) -> Bool {
      TranscriptSendCompletionReadiness.isReady(
        userMessageID: user.id,
        rows: rows ?? replacement,
        measurements: measurements,
        hasPendingMeasurement: { pending.contains($0) },
        hosts: hosts
      )
    }

    // A carried measurement prevents a layout jump, but does not authorize
    // revealing a replacement whose hosting tree has not laid out yet.
    #expect(!ready())
    assistantHost.isPresentationReady = true
    pending.insert(serverRow.layoutKey)
    #expect(!ready())
    measurements.commit(15, for: serverRow.layoutKey)
    pending.remove(serverRow.layoutKey)
    #expect(ready())

    // A width invalidation, unresolved attachment, or an additional row
    // must close the same gate even if the user bubble is already ready.
    measurements.markStale(serverRow.layoutKey)
    #expect(!ready())
    measurements.commit(15, for: serverRow.layoutKey)
    assistantHost.isAttachmentGeometryReady = false
    #expect(!ready())
    assistantHost.isAttachmentGeometryReady = true
    let error = Row(id: .error, content: .error("Send failed"), estimatedHeight: 56)
    #expect(!ready([userRow, serverRow, error, spacer]))
    #expect(!ready([serverRow, spacer]))
    #expect(ready())
  }
}
