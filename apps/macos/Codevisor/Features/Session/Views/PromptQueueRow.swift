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
      Image(systemName: "line.3.horizontal")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .frame(width: 14)
        .help("Drag to reorder")
        .accessibilityHidden(true)
      content
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
    .onTapGesture(perform: onEdit)
    .onHover { isHovered = $0 }
    .help("Edit")
    .accessibilityElement(children: .contain)
    .accessibilityActions {
      if controller.canSendQueuedPromptNow, !isBeingEdited {
        Button("Send Now") { Task { await controller.sendQueuedPromptNow(id: item.id) } }
      }
      Button("Edit", action: onEdit)
      Button("Remove") { Task { await controller.deleteQueuedPrompt(id: item.id) } }
    }
  }

  private var content: some View {
    Text(item.text)
      .font(.callout)
      .foregroundStyle(isBeingEdited ? .primary : .secondary)
      .lineLimit(2)
      .truncationMode(.tail)
      .alignmentGuide(.queueRowFirstLine) { $0[.firstTextBaseline] - textCapCenter }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityAddTraits(.isButton)
      .accessibilityHint("Edits this queued message in the composer")
      .accessibilityAction(.default, onEdit)
  }
}

private extension VerticalAlignment {
  enum QueueRowFirstLine: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
  }

  static let queueRowFirstLine = VerticalAlignment(QueueRowFirstLine.self)
}
