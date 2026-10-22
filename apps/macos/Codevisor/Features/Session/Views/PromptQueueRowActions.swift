import SwiftUI
import CodevisorCore
import CodevisorUI

struct PromptQueueRowActions: View {
  @Bindable var controller: SessionController
  let item: ServerPromptQueueItem
  let isHovered: Bool
  let isBeingEdited: Bool

  var body: some View {
    HStack(spacing: 0) {
      if controller.canSendQueuedPromptNow {
        PromptQueueIconButton(
          systemImage: "arrow.turn.right.up", help: PromptQueueActionTitle.sendNow, isRowHovered: isHovered
        ) {
          Task { await controller.sendQueuedPromptNow(id: item.id) }
        }
        .opacity(isBeingEdited ? 0 : 1)
        .allowsHitTesting(!isBeingEdited)
        .accessibilityHidden(isBeingEdited)
      }
      PromptQueueIconButton(systemImage: "trash", help: PromptQueueActionTitle.remove, isRowHovered: isHovered) {
        Task { await controller.deleteQueuedPrompt(id: item.id) }
      }
    }
  }
}

private struct PromptQueueIconButton: View {
  let systemImage: String
  let help: String
  let isRowHovered: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(isRowHovered ? .secondary : .tertiary)
        .frame(width: ComposerCardStyle.actionDiameter, height: ComposerCardStyle.actionDiameter)
        .contentShape(Circle())
    }
    .buttonStyle(HoverIconButtonStyle())
    .help(help)
    .accessibilityLabel(help)
  }
}
