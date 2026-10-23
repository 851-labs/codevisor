import CodevisorCore
import CodevisorUI
import SwiftUI

struct IOSPromptQueueRow: View {
  struct Actions {
    let edit: () -> Void
    let sendNow: () -> Void
    let remove: () -> Void
  }

  let item: ServerPromptQueueItem
  let canSendNow: Bool
  let isBusy: Bool
  let actions: Actions

  private var attachments: [ServerAttachmentRef] { item.attachments ?? [] }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      message
      if !attachments.isEmpty {
        AttachmentCountBadge(count: attachments.count)
      }
      if canSendNow {
        IOSPromptQueueSendNowButton(isBusy: isBusy, action: actions.sendNow)
      }
    }
    .frame(minHeight: Typography.minimumInteractiveTargetSize)
    .disabled(isBusy)
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button(PromptQueueActionTitle.remove, systemImage: "trash", role: .destructive, action: actions.remove)
    }
    .swipeActions(edge: .leading, allowsFullSwipe: true) {
      if canSendNow {
        Button(PromptQueueActionTitle.sendNow, systemImage: "arrow.turn.right.up", action: actions.sendNow)
          .tint(.accentColor)
      }
    }
    .contextMenu {
      if canSendNow {
        Button(PromptQueueActionTitle.sendNow, systemImage: "arrow.turn.right.up", action: actions.sendNow)
      }
      Button(PromptQueueActionTitle.edit, systemImage: "pencil", action: actions.edit)
      Button(PromptQueueActionTitle.remove, systemImage: "trash", role: .destructive, action: actions.remove)
    }
    .accessibilityActions {
      if canSendNow { Button(PromptQueueActionTitle.sendNow, action: actions.sendNow) }
      Button(PromptQueueActionTitle.edit, action: actions.edit)
      Button(PromptQueueActionTitle.remove, action: actions.remove)
    }
  }

  private var message: some View {
    Button(action: actions.edit) {
      Text(PromptQueuePreviewText.singleLine(item.text))
        .font(.body)
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityHint("Edits the queued message in the composer")
  }
}

private struct IOSPromptQueueSendNowButton: View {
  let isBusy: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        Image(systemName: "arrow.turn.right.up")
          .opacity(isBusy ? 0 : 1)
        if isBusy {
          ProgressView()
            .controlSize(.small)
        }
      }
      .composerCircleActionLabel(.secondary)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(PromptQueueActionTitle.sendNow)
    .accessibilityHint("Adds this message to the running turn")
  }
}
