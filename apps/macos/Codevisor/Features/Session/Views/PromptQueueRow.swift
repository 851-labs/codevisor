import AppKit
import SwiftUI
import CodevisorCore
import CodevisorUI

struct PromptQueueRow: View {
  @Bindable var controller: SessionController
  let item: ServerPromptQueueItem
  let selectionShape: UnevenRoundedRectangle
  let onEdit: () -> Void
  @State private var isHovered = false
  @Environment(\.displayScale) private var displayScale

  private static let textCapHeight = NSFont.preferredFont(forTextStyle: .callout).capHeight

  private var textCapCenter: CGFloat {
    (Self.textCapHeight / 2 * displayScale).rounded(.up) / displayScale
  }

  private var isBeingEdited: Bool { controller.editingQueuedPromptID == item.id }

  private var attachments: [ServerAttachmentRef] { item.attachments ?? [] }

  private var rowFill: Color {
    RowSelectionStyle.fill(isSelected: isBeingEdited, isHovered: isHovered)
  }

  var body: some View {
    HStack(alignment: .queueRowFirstLine, spacing: 8) {
      Image(systemName: PromptQueueSymbol.name(steered: item.isNextStep))
        .font(.caption)
        .foregroundStyle(.tertiary)
        .frame(width: 14)
        .help(item.isNextStep ? "" : "Drag to reorder")
        .accessibilityHidden(true)
      content
      MessageAttributionText(item.attribution)
        .fixedSize()
      if !attachments.isEmpty {
        AttachmentCountBadge(count: attachments.count)
      }
      PromptQueueRowActions(
        controller: controller,
        item: item,
        isHovered: isHovered,
        isBeingEdited: isBeingEdited
      )
    }
    .padding(.leading, 6)
    .padding(.trailing, 3)
    .padding(.vertical, 3)
    .background(selectionShape.fill(rowFill))
    .contentShape(selectionShape)
    .onTapGesture(perform: editIfQueued)
    .onHover { isHovered = $0 }
    .accessibilityElement(children: .contain)
    .accessibilityActions {
      if controller.canSendQueuedPromptNow, !isBeingEdited {
        Button(PromptQueueActionTitle.sendNow) { Task { await controller.sendQueuedPromptNow(id: item.id) } }
      }
      if !item.isNextStep {
        Button(PromptQueueActionTitle.edit, action: onEdit)
        Button(PromptQueueActionTitle.remove) { Task { await controller.deleteQueuedPrompt(id: item.id) } }
      }
    }
  }

  private func editIfQueued() {
    guard !item.isNextStep else { return }
    onEdit()
  }

  private var content: some View {
    Text(PromptQueuePreviewText.singleLine(item.text))
      .font(.callout)
      .foregroundStyle(isBeingEdited ? .primary : .secondary)
      .lineLimit(1)
      .truncationMode(.tail)
      .background(TranscriptQueueSendAnchor(id: item.id, text: item.text))
      .alignmentGuide(.queueRowFirstLine) { $0[.firstTextBaseline] - textCapCenter }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .help(item.isNextStep ? "" : PromptQueueActionTitle.edit)
      .accessibilityAddTraits(.isButton)
      .accessibilityHint(item.isNextStep ? "" : "Edits this queued message in the composer")
      .accessibilityAction(.default, editIfQueued)
  }
}

private extension VerticalAlignment {
  enum QueueRowFirstLine: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
  }

  static let queueRowFirstLine = VerticalAlignment(QueueRowFirstLine.self)
}
