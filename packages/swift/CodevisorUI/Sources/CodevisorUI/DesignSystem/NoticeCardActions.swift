import SwiftUI

struct NoticeCardActions: View {
  let actions: [ComposerNoticeCard.Action]
  let fillsWidth: Bool
  var controlSize: ControlSize = .regular

  var body: some View {
    HStack(spacing: 8) {
      ForEach(actions.indices, id: \.self) { index in
        NoticeCardButton(action: actions[index], fillsWidth: fillsWidth, controlSize: controlSize)
      }
    }
  }
}
