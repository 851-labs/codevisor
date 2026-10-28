import CodevisorCore
import CodevisorUI
import SwiftUI

extension ComposerBar {
  private static let botFieldInset: CGFloat = 6
  private static let botTextLeadingInset: CGFloat = 16
  private static let botFieldCornerRadius: CGFloat = 20
  private static let botAttachDiameter: CGFloat = 40
  private static let botSendSize = CGSize(width: 38, height: 28)
  private static let botEditorMinHeight: CGFloat = 28
  private static let botEditorMaxHeight: CGFloat = 148

  var usesBotLayout: Bool {
    controller.presentsBotConversation
      && controller.composerQuestion == nil
      && !controller.isGoalEditing
      && !controller.isEditingQueuedPrompt
  }

  var botComposer: some View {
    HStack(alignment: .bottom, spacing: 12) {
      botAttachButton
      botField
    }
  }

  var botSendButtonLabel: some View {
    Image(systemName: "arrow.up")
      .font(.system(.body, weight: .bold))
      .foregroundStyle(canSend ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.secondary.opacity(0.75)))
      .scaledFrame(width: Self.botSendSize.width, height: Self.botSendSize.height, relativeTo: .body)
      .background(
        Capsule().fill(canSend ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.16)))
      )
      .expandedHitTarget(base: Self.botSendSize.height)
  }

  private var botEditorHeight: CGFloat {
    min(max(measuredTextHeight, Self.botEditorMinHeight), Self.botEditorMaxHeight)
  }

  private var botField: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !controller.composerAttachments.isEmpty {
        ComposerAttachmentStrip(controller: controller)
      }
      HStack(alignment: .bottom, spacing: 6) {
        botEditor
        if hasDraft {
          sendButton
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
      }
    }
    .padding(.leading, Self.botTextLeadingInset)
    .padding(.trailing, Self.botFieldInset)
    .padding(.vertical, Self.botFieldInset)
    .animation(Motion.quick(reduceMotion: reduceMotion), value: hasDraft)
    .composerGlassSurface(
      shape: RoundedRectangle(cornerRadius: Self.botFieldCornerRadius),
      id: .composer,
      in: glassNamespace
    )
    .disabled(controller.isResolvingQuestion)
  }

  private var botEditor: some View {
    ZStack(alignment: .topLeading) {
      composerTextView(topInset: 0, resizesComposer: false)
        .frame(height: botEditorHeight)
        .onGeometryChange(for: CGRect.self) { proxy in
          proxy.frame(in: .global)
        } action: { frame in
          onSendSourceFrameChange?(frame)
        }

      Text(controller.composerPlaceholder)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .opacity(text.isEmpty ? 1 : 0)
        .padding(.top, 4)
        .allowsHitTesting(false)
        .accessibilityHidden(!text.isEmpty)
    }
    .padding(.trailing, hasDraft ? 0 : Self.botTextLeadingInset - Self.botFieldInset)
  }

  private var botAttachButton: some View {
    Menu {
      attachMenuItems
    } label: {
      Image(systemName: "plus")
        .font(.system(.title3, weight: .regular))
        .foregroundStyle(.primary)
        .scaledFrame(width: Self.botAttachDiameter, height: Self.botAttachDiameter, relativeTo: .body)
        .contentShape(.circle)
    }
    .menuOrder(.fixed)
    .buttonStyle(.plain)
    .glassEffect(.regular, in: .circle)
    .pointerHighlight(Circle())
    .disabled(remainingAttachmentSlots == 0 || controller.isSubmitting)
    .accessibilityLabel("Attach files")
  }
}
