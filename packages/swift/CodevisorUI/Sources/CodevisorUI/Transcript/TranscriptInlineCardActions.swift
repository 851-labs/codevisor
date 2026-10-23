import SwiftUI

struct TranscriptInlineCardActions: View {
  let actions: [TranscriptInlineCard.Action]

  var body: some View {
    HStack(spacing: 8) {
      ForEach(actions.indices, id: \.self) { index in
        TranscriptInlineCardButton(action: actions[index])
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}
