import SwiftUI
import CodevisorCore
import CodevisorUI
import UniformTypeIdentifiers

struct PromptQueueView: View {
  private var cardStyle = ComposerCardStyle()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Bindable var controller: SessionController
  let glassNamespace: Namespace.ID
  let onEditInComposer: (ServerPromptQueueItem) -> Void
  @State private var draggingID: String?

  private static let rowInset: CGFloat = 6
  private static let maximumListHeight: CGFloat = 220

  init(
    controller: SessionController,
    glassNamespace: Namespace.ID,
    onEditInComposer: @escaping (ServerPromptQueueItem) -> Void
  ) {
    self.controller = controller
    self.glassNamespace = glassNamespace
    self.onEditInComposer = onEditInComposer
  }

  var body: some View {
    ViewThatFits(in: .vertical) {
      rows
      ScrollView { rows }
        .scrollIndicators(.automatic)
    }
    .frame(maxHeight: Self.maximumListHeight)
    .fixedSize(horizontal: false, vertical: true)
    .padding(Self.rowInset)
    .frame(maxWidth: .infinity, alignment: .leading)
    .composerGlassSurface(shape: cardStyle.shape, id: .queue, in: glassNamespace)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Queued messages")
  }

  private var rows: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(controller.queuedPrompts) { item in
        PromptQueueRow(
          controller: controller,
          item: item,
          selectionShape: selectionShape(for: item),
          onEdit: { onEditInComposer(item) }
        )
        .onDrag {
          draggingID = item.id
          return NSItemProvider(object: item.id as NSString)
        }
        .onDrop(
          of: [.plainText],
          delegate: PromptQueueDropDelegate(targetID: item.id, draggingID: $draggingID, move: move)
        )
      }
      ForEach(controller.unsentQueuedMessages) { message in
        PromptQueueUnsentRow(
          controller: controller,
          message: message,
          selectionShape: selectionShape(for: message.id.uuidString.lowercased())
        )
      }
    }
    .animation(Motion.quick(reduceMotion: reduceMotion), value: rowIDs)
  }

  private var rowIDs: [String] {
    controller.queuedPrompts.map(\.id) + controller.unsentQueuedMessages.map { $0.id.uuidString.lowercased() }
  }

  private func selectionShape(for item: ServerPromptQueueItem) -> UnevenRoundedRectangle {
    selectionShape(for: item.id)
  }

  private func selectionShape(for id: String) -> UnevenRoundedRectangle {
    let nested = cardStyle.cornerRadius - Self.rowInset
    let ids = rowIDs
    let top = id == ids.first ? nested : RowSelectionStyle.cornerRadius
    let bottom = id == ids.last ? nested : RowSelectionStyle.cornerRadius
    return UnevenRoundedRectangle(
      topLeadingRadius: top,
      bottomLeadingRadius: bottom,
      bottomTrailingRadius: bottom,
      topTrailingRadius: top,
      style: .continuous
    )
  }

  private func move(_ draggedID: String, onto targetID: String) {
    let current = controller.queuedPrompts.map(\.id)
    let ids = QueuedPromptOrder.moving(draggedID, onto: targetID, in: current)
    guard ids != current else { return }
    Task { await controller.reorderQueuedPrompts(ids: ids) }
  }
}

private struct PromptQueueDropDelegate: DropDelegate {
  let targetID: String
  @Binding var draggingID: String?
  let move: (String, String) -> Void

  func dropEntered(info: DropInfo) {
    guard let draggingID, draggingID != targetID else { return }
    move(draggingID, targetID)
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func validateDrop(info: DropInfo) -> Bool {
    draggingID != nil
  }

  func performDrop(info: DropInfo) -> Bool {
    draggingID = nil
    return true
  }
}
