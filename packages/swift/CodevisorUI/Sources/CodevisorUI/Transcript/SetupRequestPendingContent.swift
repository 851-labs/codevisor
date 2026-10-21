import SwiftUI

struct SetupRequestPendingContent: View {
  let copy: SetupRequestCopy
  let actions: [ComposerNoticeCard.Action]

  #if os(iOS)
    var body: some View {
      VStack(alignment: .leading, spacing: SetupRequestCardMetrics.actionSpacing) {
        text
        HStack(spacing: 14) {
          Spacer(minLength: 0)
          ForEach(actions.indices, id: \.self) { index in
            button(actions[index])
          }
        }
      }
    }

    private func button(_ action: ComposerNoticeCard.Action) -> some View {
      Button(action: action.perform) {
        Text(action.title)
          .capsuleActionLabel()
      }
      .buttonStyle(.plain)
      .foregroundStyle(action.emphasis == .primary ? Color.accentColor : Color.secondary)
      .pointerHighlight(Capsule())
    }
  #else
    var body: some View {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 16) {
          text
          Spacer(minLength: 0)
          NoticeCardActions(actions: actions, fillsWidth: false)
        }
        VStack(alignment: .leading, spacing: SetupRequestCardMetrics.actionSpacing) {
          text
          NoticeCardActions(actions: actions, fillsWidth: true)
        }
      }
    }
  #endif

  private var text: NoticeCardText {
    NoticeCardText(title: copy.title, detail: copy.detail, systemImage: copy.symbol, accent: .accentColor)
  }
}
