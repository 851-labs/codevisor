import SwiftUI

struct SetupRequestContent: View {
  let copy: SetupRequestCopy
  let actions: [ComposerNoticeCard.Action]

  var body: some View {
    if copy.isPending {
      VStack(alignment: .leading, spacing: SetupRequestCardMetrics.actionSpacing) {
        NoticeCardText(title: copy.title, detail: copy.detail, systemImage: copy.symbol, accent: .accentColor)
        NoticeCardActions(actions: actions, fillsWidth: true, controlSize: SetupRequestCardMetrics.controlSize)
      }
    } else {
      SetupRequestResolvedRow(copy: copy)
    }
  }
}
