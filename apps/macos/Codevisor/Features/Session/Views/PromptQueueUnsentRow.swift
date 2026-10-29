import SwiftUI
import CodevisorCore
import CodevisorUI

struct PromptQueueUnsentRow: View {
  let controller: SessionController
  let message: UnsentQueuedMessage
  let selectionShape: UnevenRoundedRectangle
  @State private var isHovered = false

  private var isUndelivered: Bool {
    message.delivery?.isFailed == true
  }

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      statusIcon
        .frame(width: 14)
      VStack(alignment: .leading, spacing: 1) {
        Text(PromptQueuePreviewText.singleLine(message.text))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
        if isUndelivered {
          Text("Not Delivered")
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if message.attachmentCount > 0 {
        AttachmentCountBadge(count: message.attachmentCount)
      }
      if isUndelivered {
        PromptQueueIconButton(systemImage: "arrow.clockwise", help: "Try Again", isRowHovered: isHovered) {
          Task { await controller.retryUnsentMessage(id: message.id) }
        }
        PromptQueueIconButton(systemImage: "trash", help: "Delete", isRowHovered: isHovered) {
          controller.deleteUnsentMessage(id: message.id)
        }
      }
    }
    .padding(.leading, 6)
    .padding(.trailing, 3)
    .padding(.vertical, 3)
    .frame(minHeight: ComposerCardStyle.actionDiameter + 6)
    .background(selectionShape.fill(RowSelectionStyle.fill(isSelected: false, isHovered: isHovered)))
    .contentShape(selectionShape)
    .onHover { isHovered = $0 }
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private var statusIcon: some View {
    switch message.delivery {
    case .failed:
      Image(systemName: "exclamationmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.red)
        .accessibilityLabel("Not Delivered")
    case .sending:
      ProgressView()
        .controlSize(.mini)
        .accessibilityLabel("Sending")
    case nil:
      Image(systemName: "clock")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .accessibilityLabel("Waiting to queue")
    }
  }
}
