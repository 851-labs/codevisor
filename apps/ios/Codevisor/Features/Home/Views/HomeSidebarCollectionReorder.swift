import CodevisorUI
import UIKit

final class HomeSidebarCollectionReorder: NSObject, UICollectionViewDragDelegate, UICollectionViewDropDelegate {
  typealias Row = HomeSidebarCollectionRow

  weak var controller: HomeSidebarCollectionController?
  private(set) var dragged: Row?
  private(set) var collapsedSection: UUID?

  var isDragging: Bool { dragged != nil }

  func collectionView(
    _ collectionView: UICollectionView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath
  ) -> [UIDragItem] {
    guard let row = controller?.row(at: indexPath), row.drag != nil else { return [] }

    let item = UIDragItem(itemProvider: NSItemProvider())
    item.localObject = row.id
    return [item]
  }

  func collectionView(_ collectionView: UICollectionView, dragSessionWillBegin session: UIDragSession) {
    dragged = (session.items.first?.localObject as? Row.ID).flatMap { controller?.row($0) }
    guard let section = dragged?.draggedSection, hasVisibleMembers(of: section) else { return }

    collapsedSection = section
    controller?.apply(animated: true)
  }

  func collectionView(_ collectionView: UICollectionView, dragSessionDidEnd session: UIDragSession) {
    dragged = nil
    collapsedSection = nil
    controller?.finishDrag()
  }

  func collectionView(
    _ collectionView: UICollectionView, dragSessionIsRestrictedToDraggingApplication session: UIDragSession
  ) -> Bool {
    true
  }

  func collectionView(
    _ collectionView: UICollectionView, dragSessionAllowsMoveOperation session: UIDragSession
  )
    -> Bool
  {
    true
  }

  func collectionView(
    _ collectionView: UICollectionView, dragPreviewParametersForItemAt indexPath: IndexPath
  )
    -> UIDragPreviewParameters?
  {
    previewParameters(for: indexPath, in: collectionView)
  }

  func collectionView(
    _ collectionView: UICollectionView, dropPreviewParametersForItemAt indexPath: IndexPath
  )
    -> UIDragPreviewParameters?
  {
    previewParameters(for: indexPath, in: collectionView)
  }

  func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
    session.localDragSession != nil
  }

  func collectionView(
    _ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
    withDestinationIndexPath destinationIndexPath: IndexPath?
  ) -> UICollectionViewDropProposal {
    guard session.localDragSession != nil else { return UICollectionViewDropProposal(operation: .cancel) }
    guard let dragged, dragged.draggedSection != nil else { return itemProposal(at: destinationIndexPath) }

    follow(dragged.id, to: session.location(in: collectionView).y, in: collectionView)
    return UICollectionViewDropProposal(operation: .move, intent: .unspecified)
  }

  func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator)
  {
    guard let dragged, dragged.draggedSection != nil, let item = coordinator.items.first,
      let source = item.sourceIndexPath, let order = controller?.outlineIDs(),
      let landing = order.firstIndex(of: dragged.id)
    else { return }

    coordinator.drop(item.dragItem, toItemAt: IndexPath(item: landing, section: source.section))
    if let index = dragged.outlineIndex { controller?.move(index, to: destination(of: dragged.id, in: order)) }
  }

  func didReorder(_ transaction: NSDiffableDataSourceTransaction<Row.Section, Row.ID>) {
    guard let dragged, let source = dragged.outlineIndex,
      let final = transaction.sectionTransactions.first(where: { $0.sectionIdentifier == .outline })?.finalSnapshot
    else { return }

    controller?.move(source, to: destination(of: dragged.id, in: final.items))
  }

  private func itemProposal(at destination: IndexPath?) -> UICollectionViewDropProposal {
    guard isOutline(destination) else { return UICollectionViewDropProposal(operation: .cancel) }
    return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
  }

  private func follow(_ header: Row.ID, to midY: CGFloat, in collectionView: UICollectionView) {
    guard let controller else { return }

    let order = controller.outlineIDs()
    let drag = HomeSidebarSectionDrag(header: header, order: order, row: controller.row)
    guard let next = drag.order(at: midY, frames: frames(of: order, in: collectionView)) else { return }
    controller.showOutline(next)
  }

  private func frames(of order: [Row.ID], in collectionView: UICollectionView) -> [Row.ID: CGRect] {
    var frames: [Row.ID: CGRect] = [:]
    for (index, id) in order.enumerated() {
      frames[id] = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame
    }
    return frames
  }

  private func destination(of id: Row.ID, in order: [Row.ID]) -> Int {
    guard let index = order.firstIndex(of: id) else { return 0 }

    let above = order[..<index].compactMap { controller?.row($0)?.outlineIndex }
    return above.last.map { $0 + 1 } ?? 0
  }

  private func hasVisibleMembers(of section: UUID) -> Bool {
    controller?.outlineIDs().contains { controller?.row($0)?.member == section } ?? false
  }

  private func isOutline(_ indexPath: IndexPath?) -> Bool {
    guard let indexPath else { return false }
    return controller?.section(at: indexPath.section) == .outline
  }

  func headerPreview(at indexPath: IndexPath, in collectionView: UICollectionView) -> UITargetedPreview? {
    guard let cell = collectionView.cellForItem(at: indexPath),
      let parameters = previewParameters(for: indexPath, in: collectionView)
    else { return nil }
    return UITargetedPreview(view: cell, parameters: parameters)
  }

  private func previewParameters(
    for indexPath: IndexPath, in collectionView: UICollectionView
  )
    -> UIDragPreviewParameters?
  {
    guard let row = controller?.row(at: indexPath), let top = row.previewTopInset,
      let cell = collectionView.cellForItem(at: indexPath)
    else { return nil }

    let parameters = UIDragPreviewParameters()
    let pill = CGRect(x: 0, y: top, width: cell.bounds.width, height: cell.bounds.height - top)
    parameters.visiblePath = UIBezierPath(roundedRect: pill, cornerRadius: pill.height / 2)
    parameters.backgroundColor = collectionView.backgroundColor
    return parameters
  }
}
