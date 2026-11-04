import CodevisorCore
import CodevisorUI
import SwiftUI

struct IOSPromptQueueAccessory: View {
  @Bindable var controller: SessionController
  let glassNamespace: Namespace.ID
  @Binding var isPresentingQueue: Bool
  let cardStyle = ComposerCardStyle()

  private var firstItem: QueuedMessagePreview? {
    controller.queuedMessagePreviews.first
  }

  private var count: Int {
    controller.queuedMessagePreviews.count
  }

  private var hasUndelivered: Bool {
    controller.unsentQueuedMessages.contains { $0.delivery?.isFailed == true }
  }

  private var leadingSymbol: String {
    if hasUndelivered { return "exclamationmark.circle.fill" }
    return PromptQueueSymbol.queued
  }

  private var countText: String {
    count == 1 ? "1 message" : "\(count) messages"
  }

  var body: some View {
    Button {
      isPresentingQueue = true
    } label: {
      HStack(spacing: 8) {
        Image(systemName: leadingSymbol)
          .font(.subheadline.weight(.medium))
          .foregroundStyle(hasUndelivered ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
        if let firstItem {
          Text(PromptQueuePreviewText.singleLine(firstItem.text))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .background(TranscriptQueueSendAnchor(id: firstItem.id, text: firstItem.text))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if count > 1 {
          IOSPromptQueueCountBadge(count: count)
        }
        Image(systemName: "chevron.up")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, ComposerCardStyle.contentPadding + 2)
      .padding(.vertical, ComposerCardStyle.contentPadding)
      .frame(maxWidth: .infinity, minHeight: Typography.minimumInteractiveTargetSize, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .composerGlassSurface(shape: cardStyle.shape, id: .queue, in: glassNamespace)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(hasUndelivered ? "Queued, \(countText), some not delivered" : "Queued, \(countText)")
    .accessibilityValue(firstItem.map { "Next: \($0.text)" } ?? "")
    .accessibilityHint("Shows queued messages")
  }
}

private struct IOSPromptQueueCountBadge: View {
  let count: Int

  var body: some View {
    Text("\(count)")
      .font(.caption.weight(.semibold).monospacedDigit())
      .foregroundStyle(.secondary)
      .contentTransition(.numericText())
      .padding(.horizontal, 7)
      .scaledFrame(height: 22, relativeTo: .caption)
      .background(Capsule().fill(Color.primary.opacity(0.08)))
      .fixedSize()
  }
}
