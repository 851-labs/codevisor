import CodevisorCore
import CodevisorUI
import SwiftUI

struct IOSPromptQueueAccessory: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Bindable var controller: SessionController
  let glassNamespace: Namespace.ID
  @Binding var isPresentingQueue: Bool
  let sendAnimation: IOSQueueSendAnimation

  private var firstItem: ServerPromptQueueItem? {
    controller.queuedPrompts.first
  }

  private var count: Int {
    controller.queuedPrompts.count
  }

  private var countText: String {
    count == 1 ? "1 message" : "\(count) messages"
  }

  var body: some View {
    Button {
      isPresentingQueue = true
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "clock")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.secondary)
        if let firstItem {
          Text(PromptQueuePreviewText.singleLine(firstItem.text))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
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
      .opacity(sendAnimation.isFormingQueue ? 0 : 1)
    }
    .buttonStyle(.plain)
    .modifier(
      QueueGlassSurface(
        isFormingQueue: sendAnimation.isFormingQueue,
        glassNamespace: glassNamespace
      )
    )
    .background { IOSQueueSendTarget(animation: sendAnimation) }
    .keyframeAnimator(initialValue: CGFloat(1), trigger: sendAnimation.arrival) { [reduceMotion] content, scale in
      content.scaleEffect(reduceMotion ? 1 : scale)
    } keyframes: { _ in
      CubicKeyframe(1.025, duration: 0.12)
      SpringKeyframe(1, duration: 0.3, spring: .smooth)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Queued, \(countText)")
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

private struct QueueGlassSurface: ViewModifier {
  var cardStyle = ComposerCardStyle()
  let isFormingQueue: Bool
  let glassNamespace: Namespace.ID

  func body(content: Content) -> some View {
    if isFormingQueue {
      content
    } else {
      content.composerGlassSurface(shape: cardStyle.shape, id: .queue, in: glassNamespace)
    }
  }
}
