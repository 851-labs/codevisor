import SwiftUI
import UIKit

final class HomeSidebarCollectionController: NSObject, UICollectionViewDelegate {
  typealias Row = HomeSidebarCollectionRow
  typealias DataSource = UICollectionViewDiffableDataSource<Row.Section, Row.ID>

  let collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
  private var dataSource: DataSource?
  private let cells = HomeSidebarCollectionCells()
  private let reorder = HomeSidebarCollectionReorder()
  private var view: HomeSidebarCollection?
  private var rows: [Row.ID: Row] = [:]
  private var appearance: HomeSidebarCollection.Appearance?
  private var isRefreshing = false

  override init() {
    super.init()
    dataSource = makeDataSource()
    reorder.controller = self
    collectionView.delegate = self
    collectionView.dragDelegate = reorder
    collectionView.dropDelegate = reorder
    collectionView.dragInteractionEnabled = true
    collectionView.refreshControl = makeRefreshControl()
  }

  var currentAppearance: HomeSidebarCollection.Appearance { appearance ?? .plain }

  func update(with view: HomeSidebarCollection, environment: EnvironmentValues) {
    self.view = view
    cells.environment = environment
    cells.select = { [weak self] id in self?.view?.onSelect(id) }
    rows = Dictionary(view.rows.map { ($0.id, $0) }) { first, _ in first }
    guard !reorder.isDragging else { return }

    let changedAppearance = adopt(view.appearance)
    apply(animated: view.animates && !changedAppearance)
    reconfigureVisibleCells()
    syncSelection()
  }

  func row(_ id: Row.ID) -> Row? { rows[id] }

  func row(at indexPath: IndexPath) -> Row? {
    dataSource?.itemIdentifier(for: indexPath).flatMap(row)
  }

  func outlineIDs() -> [Row.ID] {
    dataSource?.snapshot(for: .outline).items ?? []
  }

  func section(at index: Int) -> Row.Section? {
    dataSource?.sectionIdentifier(for: index)
  }

  func apply(animated: Bool) {
    guard let view, let dataSource else { return }

    let snapshots = HomeSidebarCollectionSnapshots(
      rows: view.rows, appearance: view.appearance, collapsedSection: reorder.collapsedSection)
    dataSource.apply(snapshots.outline, to: .outline, animatingDifferences: animated)
    applyArchived(snapshots.archived, animated: animated)
  }

  func move(_ source: Int, to destination: Int) {
    view?.onMove(source, destination)
  }

  func showOutline(_ ids: [Row.ID]) {
    var snapshot = NSDiffableDataSourceSectionSnapshot<Row.ID>()
    snapshot.append(ids)
    dataSource?.apply(snapshot, to: .outline, animatingDifferences: view?.animates ?? true)
  }

  func finishDrag() {
    apply(animated: view?.animates ?? true)
    reconfigureVisibleCells()
    syncSelection()
  }

  func collectionView(
    _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard let indexPath = indexPaths.first, let menu = row(at: indexPath)?.menu, !menu.isEmpty else { return nil }
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in HomeSidebarUIMenu.make(menu) }
  }

  func collectionView(
    _ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration,
    highlightPreviewForItemAt indexPath: IndexPath
  ) -> UITargetedPreview? {
    reorder.headerPreview(at: indexPath, in: collectionView)
  }

  func collectionView(
    _ collectionView: UICollectionView, contextMenuConfiguration configuration: UIContextMenuConfiguration,
    dismissalPreviewForItemAt indexPath: IndexPath
  ) -> UITargetedPreview? {
    reorder.headerPreview(at: indexPath, in: collectionView)
  }

  func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
    guard let row = row(at: indexPath) else { return false }
    return row.selectionID != nil
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    guard let row = row(at: indexPath) else { return }

    if let id = row.selectionID { view?.onSelect(id) }
    if !(view?.isSelectable ?? false) || row.selectionID == nil {
      collectionView.deselectItem(at: indexPath, animated: true)
    }
  }

  private func makeDataSource() -> DataSource {
    let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Row.ID> { [weak self] cell, _, id in
      guard let self, let row = rows[id] else { return }
      cells.configure(cell, row: row, appearance: currentAppearance)
    }
    let dataSource = DataSource(collectionView: collectionView) { collectionView, indexPath, id in
      collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
    }
    let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
      elementKind: UICollectionView.elementKindSectionHeader
    ) { [weak self] cell, _, _ in
      guard let self, let row = rows[.archivedHeader] else { return }
      cells.configure(cell, row: row, appearance: currentAppearance)
    }
    dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
      collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
    }
    dataSource.reorderingHandlers.canReorderItem = { [weak self] id in self?.rows[id]?.drag != nil }
    dataSource.reorderingHandlers.didReorder = { [weak self] transaction in self?.reorder.didReorder(transaction) }
    return dataSource
  }

  private func adopt(_ next: HomeSidebarCollection.Appearance) -> Bool {
    guard next != appearance else { return false }

    appearance = next
    collectionView.backgroundColor = HomeSidebarHeaderMetrics.listBackground(isConversation: next.isConversation)
    collectionView.setCollectionViewLayout(HomeSidebarCollectionLayout.make(for: self), animated: false)
    return true
  }

  private func applyArchived(_ archived: NSDiffableDataSourceSectionSnapshot<Row.ID>, animated: Bool) {
    guard let dataSource else { return }
    guard archived.items.isEmpty, rows[.archivedHeader] == nil else {
      dataSource.apply(archived, to: .archived, animatingDifferences: animated)
      return
    }

    var snapshot = dataSource.snapshot()
    guard snapshot.sectionIdentifiers.contains(.archived) else { return }
    snapshot.deleteSections([.archived])
    dataSource.apply(snapshot, animatingDifferences: animated)
  }

  private func reconfigureVisibleCells() {
    for indexPath in collectionView.indexPathsForVisibleItems {
      guard let cell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell,
        let row = row(at: indexPath)
      else { continue }
      cells.configure(cell, row: row, appearance: currentAppearance)
    }
    reconfigureArchivedHeader()
  }

  private func reconfigureArchivedHeader() {
    guard currentAppearance.isConversation, let row = rows[.archivedHeader],
      let index = dataSource?.index(for: .archived)
    else { return }

    let indexPath = IndexPath(item: 0, section: index)
    let kind = UICollectionView.elementKindSectionHeader
    guard
      let header = collectionView.supplementaryView(forElementKind: kind, at: indexPath) as? UICollectionViewListCell
    else { return }
    cells.configure(header, row: row, appearance: currentAppearance)
  }

  private func syncSelection() {
    collectionView.allowsSelection = true
    guard let view, view.isSelectable else { return }

    let selected = view.selectedID.flatMap { id in view.rows.first { $0.selectionID == id }?.id }
    let target = selected.flatMap { dataSource?.indexPath(for: $0) }
    for indexPath in collectionView.indexPathsForSelectedItems ?? [] where indexPath != target {
      collectionView.deselectItem(at: indexPath, animated: false)
    }
    guard let target, !(collectionView.indexPathsForSelectedItems ?? []).contains(target) else { return }
    collectionView.selectItem(at: target, animated: false, scrollPosition: [])
  }

  private func makeRefreshControl() -> UIRefreshControl {
    let control = UIRefreshControl()
    control.addAction(UIAction { [weak self] _ in self?.refresh(control) }, for: .valueChanged)
    return control
  }

  private func refresh(_ control: UIRefreshControl) {
    guard let view, !isRefreshing else { return }

    isRefreshing = true
    Task {
      await view.onRefresh()
      control.endRefreshing()
      isRefreshing = false
    }
  }
}
