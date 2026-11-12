import CodevisorCore
import SwiftUI

struct BotCreateHeader: View {
  private static let avatarSize: CGFloat = 88

  let title: String
  let editor: BotEditorModel
  let editMascot: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Text(title)
        .font(.title3.weight(.semibold))
        .foregroundStyle(.primary)
      BotEditableAvatar(editor: editor, size: Self.avatarSize, edit: editMascot)
    }
    .frame(maxWidth: .infinity)
    .padding(.bottom, 8)
  }
}
