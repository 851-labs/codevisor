import CodevisorCore
import SwiftUI

public struct TranscriptMoreDetailsButton: View {
  let turn: AssistantTurn
  @Environment(\.transcriptController) private var controller
  @State private var loading = false

  public init(turn: AssistantTurn) { self.turn = turn }

  public var body: some View {
    if let itemID = turn.deferredDetailItemId {
      HStack {
        if turn.detailPreviousBefore != nil {
          pageButton("Previous details", itemID: itemID, previous: true)
        }
        if turn.detailNextAfter != nil || (turn.hasDeferredWorkedDetails && !turn.hasHydratedWorkedDetails) {
          pageButton(turn.hasHydratedWorkedDetails ? "Next details" : "Load details", itemID: itemID, previous: false)
        }
        if loading { ProgressView().controlSize(.small) }
      }
      .disabled(loading)
    }
  }

  private func pageButton(_ title: String, itemID: String, previous: Bool) -> some View {
    Button(title) {
      loading = true
      Task {
        _ = await controller?.loadTranscriptDetails(itemID, previous: previous)
        loading = false
      }
    }
  }
}
