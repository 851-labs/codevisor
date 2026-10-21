import SwiftUI

struct NoticeCardButton: View {
  let action: ComposerNoticeCard.Action
  let fillsWidth: Bool
  let controlSize: ControlSize

  var body: some View {
    if action.emphasis == .primary {
      label.buttonStyle(.borderedProminent)
    } else {
      label.buttonStyle(.bordered).tint(.primary)
    }
  }

  private var label: some View {
    Button(action: action.perform) {
      Text(action.title)
        .lineLimit(1)
        .frame(maxWidth: fillsWidth ? .infinity : nil)
    }
    .controlSize(controlSize)
    .fixedSize(horizontal: !fillsWidth, vertical: false)
  }
}
