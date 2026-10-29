import CodevisorCore
import CodevisorUI
import SwiftUI

struct IOSPromptQueueUnsentRow: View {
  let message: UnsentQueuedMessage
  let retry: () -> Void
  let delete: () -> Void

  private var isUndelivered: Bool {
    message.delivery?.isFailed == true
  }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(PromptQueuePreviewText.singleLine(message.text))
          .font(.body)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
        if isUndelivered {
          Label("Not Delivered", systemImage: "exclamationmark.circle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
        }
      }
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      if message.attachmentCount > 0 {
        AttachmentCountBadge(count: message.attachmentCount)
      }
      trailingStatus
    }
    .frame(minHeight: Typography.minimumInteractiveTargetSize)
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      if isUndelivered {
        Button("Delete", systemImage: "trash", role: .destructive, action: delete)
      }
    }
    .contextMenu {
      if isUndelivered {
        Button("Try Again", systemImage: "arrow.clockwise", action: retry)
        Button("Delete", systemImage: "trash", role: .destructive, action: delete)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityActions {
      if isUndelivered {
        Button("Try Again", action: retry)
        Button("Delete", action: delete)
      }
    }
  }

  @ViewBuilder
  private var trailingStatus: some View {
    switch message.delivery {
    case .failed:
      Button(action: retry) {
        Image(systemName: "arrow.clockwise")
          .composerCircleActionLabel(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Try Again")
    case .sending:
      ProgressView()
        .controlSize(.small)
        .accessibilityLabel("Sending")
    case nil:
      EmptyView()
    }
  }
}
