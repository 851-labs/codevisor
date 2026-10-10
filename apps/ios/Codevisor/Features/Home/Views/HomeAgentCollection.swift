import CodevisorCore
import SwiftUI
import UIKit

/// What the root list asks of its owner.
struct HomeAgentCollectionActions {
  /// A workspace tapped on a phone: its page opens.
  var open: (AgentSidebarRow) -> Void = { _ in }
  /// A workspace chosen beside the split's detail.
  var select: (UUID) -> Void = { _ in }
  var setWorkspaceExpanded: (UUID, Bool) -> Void = { _, _ in }
  var setGroupExpanded: (HomeSidebarGroup, Bool) -> Void = { _, _ in }
  /// A row dropped somewhere new; the store has it there on return.
  var drop: (HomeListItem, HomeListDrop) -> Void = { _, _ in }
  var workspaceMenu: (AgentSidebarRow, AgentSidebarRow?) -> UIMenu? = { _, _ in nil }
  var archive: (UUID) -> Void = { _ in }
  /// A folder's own actions, from a swipe as from its menu. Deleting may
  /// archive the workspaces filed in it too.
  var renameGroup: (HomeSidebarGroup) -> Void = { _ in }
  var deleteGroup: (HomeSidebarGroup, _ archivingWorkspaces: Bool) -> Void = { _, _ in }
  var refresh: () async -> Void = {}
}

/// The root list as Notes lists folders and notes: a collection view, so a
/// workspace dragged over a folder's row highlights it and drops into it,
/// and a row with nothing in it has no disclosure. Rows are drawn by
/// SwiftUI inside the cells.
struct HomeAgentCollection: UIViewControllerRepresentable {
  let environment: AppEnvironment
  /// The list as the store has it now.
  let model: () -> HomeListModel
  let expandedWorkspaces: Set<UUID>
  let isExpanded: (HomeSidebarGroup) -> Bool
  /// The split's selected workspace; nil on a phone, where rows push.
  let selection: UUID?
  let isSelectionList: Bool
  let actions: HomeAgentCollectionActions

  func makeUIViewController(context: Context) -> HomeAgentCollectionController {
    HomeAgentCollectionController(isSelectionList: isSelectionList)
  }

  func updateUIViewController(_ controller: HomeAgentCollectionController, context: Context) {
    controller.update(self)
  }
}

final class HomeAgentCollectionController: UIViewController, UICollectionViewDelegate,
  UICollectionViewDragDelegate, UICollectionViewDropDelegate
{
  private let isSelectionList: Bool
  private var list: HomeAgentCollection?
  private var model = HomeListModel(nodes: [], grouping: .none)
  private var collectionView: UICollectionView!
  private var dataSource: UICollectionViewDiffableDataSource<HomeListSection, HomeListItem>!

  init(isSelectionList: Bool) {
    self.isSelectionList = isSelectionList
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
    collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    collectionView.delegate = self
    collectionView.dragDelegate = self
    collectionView.dropDelegate = self
    collectionView.dragInteractionEnabled = true
    let refresh = UIRefreshControl()
    refresh.addAction(
      UIAction { [weak self, weak refresh] _ in
        Task { @MainActor in
          await self?.list?.actions.refresh()
          refresh?.endRefreshing()
        }
      }, for: .valueChanged)
    collectionView.refreshControl = refresh
    view.addSubview(collectionView)
    makeDataSource()
  }

  func update(_ list: HomeAgentCollection) {
    self.list = list
    loadViewIfNeeded()
    reload(animated: view.window != nil)
  }

  // MARK: - Layout and cells

  private func makeLayout() -> UICollectionViewLayout {
    UICollectionViewCompositionalLayout { [weak self] index, environment in
      var config = UICollectionLayoutListConfiguration(
        appearance: self?.isSelectionList == true ? .sidebar : .insetGrouped)
      // Headers name the two lists when both are there.
      config.headerMode = self?.dataSource?.snapshot().numberOfSections ?? 0 > 1 ? .supplementary : .none
      config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
        self?.swipeActions(at: indexPath)
      }
      return NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
    }
  }

  /// A workspace archives; a folder deletes (after asking) or renames.
  private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
    switch dataSource.itemIdentifier(for: indexPath) {
    case let .workspace(id):
      let archive = UIContextualAction(style: .destructive, title: "Archive") { [weak self] _, _, done in
        self?.list?.actions.archive(id)
        done(true)
      }
      archive.image = UIImage(systemName: "archivebox")
      return UISwipeActionsConfiguration(actions: [archive])
    case let .group(id):
      guard let group = model.group(id), group.folder != nil else { return nil }
      // The row slides back: deleting asks first, renaming asks for a name.
      let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
        self?.confirmDelete(group)
        done(false)
      }
      delete.image = UIImage(systemName: "trash")
      let rename = UIContextualAction(style: .normal, title: "Rename") { [weak self] _, _, done in
        self?.list?.actions.renameGroup(group)
        done(true)
      }
      rename.image = UIImage(systemName: "pencil")
      rename.backgroundColor = .systemBlue
      let actions = UISwipeActionsConfiguration(actions: [delete, rename])
      actions.performsFirstActionWithFullSwipe = false
      return actions
    case nil:
      return nil
    }
  }

  private func makeDataSource() {
    let cell = UICollectionView.CellRegistration<HomeListCell, HomeListItem> { [weak self] cell, _, item in
      self?.configure(cell, item)
    }
    let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
      elementKind: UICollectionView.elementKindSectionHeader
    ) { [weak self] header, _, indexPath in
      guard let self else { return }
      var content =
        isSelectionList ? UIListContentConfiguration.header() : .prominentInsetGroupedHeader()
      let section = dataSource.snapshot().sectionIdentifiers[indexPath.section]
      content.text =
        section == .workspaces ? "Workspaces" : model.grouping == .project ? "Projects" : "Folders"
      header.contentConfiguration = content
    }
    dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, indexPath, item in
      view.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
    }
    dataSource.supplementaryViewProvider = { view, _, indexPath in
      view.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
    }
    // Disclosure is this device's choice for workspaces, synced for folders.
    dataSource.sectionSnapshotHandlers.willExpandItem = { [weak self] item in self?.setExpanded(item, true) }
    dataSource.sectionSnapshotHandlers.willCollapseItem = { [weak self] item in self?.setExpanded(item, false) }
  }

  private func setExpanded(_ item: HomeListItem, _ expanded: Bool) {
    switch item {
    case let .workspace(id): list?.actions.setWorkspaceExpanded(id, expanded)
    case let .group(id): if let group = model.group(id) { list?.actions.setGroupExpanded(group, expanded) }
    }
  }

  private func configure(_ cell: HomeListCell, _ item: HomeListItem) {
    guard let environment = list?.environment else { return }
    let disclosure = UICellAccessory.OutlineDisclosureOptions(style: .cell, tintColor: .secondaryLabel)
    switch item {
    case let .workspace(id):
      guard let row = model.placements[id]?.row else { return }
      let draw = { (cell: HomeListCell, isSelected: Bool) in
        cell.drawnSelected = isSelected
        cell.contentConfiguration = UIHostingConfiguration {
          HomeListWorkspaceRow(row: row, isSelected: isSelected).environment(environment)
        }
      }
      draw(cell, cell.isSelected)
      // Beside the detail, a selected row's text turns to the selection's.
      // Only a change of selection redraws it: a swipe must leave it drawn.
      cell.configurationUpdateHandler =
        isSelectionList
        ? { cell, state in
          guard let cell = cell as? HomeListCell, cell.drawnSelected != state.isSelected else { return }
          draw(cell, state.isSelected)
        } : nil
      cell.accessories =
        !row.children.isEmpty
        ? [.outlineDisclosure(options: disclosure)] : isSelectionList ? [] : [.disclosureIndicator()]
    case let .group(id):
      guard let group = model.group(id) else { return }
      cell.configurationUpdateHandler = nil
      cell.contentConfiguration = UIHostingConfiguration { HomeListGroupRow(group: group) }
      // An empty folder has nothing to disclose.
      var header = disclosure
      header.style = .header
      cell.accessories = group.rows.isEmpty ? [] : [.outlineDisclosure(options: header)]
    }
  }

  // MARK: - Contents

  private func reload(animated: Bool) {
    guard let list else { return }
    model = list.model()
    var sections: [HomeListSection] = []
    if !model.groups.isEmpty { sections.append(.groups) }
    if !model.loose.isEmpty { sections.append(.workspaces) }
    if dataSource.snapshot().sectionIdentifiers != sections {
      var base = NSDiffableDataSourceSnapshot<HomeListSection, HomeListItem>()
      base.appendSections(sections)
      dataSource.apply(base, animatingDifferences: false)
      collectionView.collectionViewLayout.invalidateLayout()
    }
    if sections.contains(.groups) {
      var snapshot = NSDiffableDataSourceSectionSnapshot<HomeListItem>()
      for group in model.groups {
        snapshot.append([.group(group.id)])
        append(group.rows, under: .group(group.id), to: &snapshot)
        if !group.rows.isEmpty, list.isExpanded(group) { snapshot.expand([.group(group.id)]) }
      }
      dataSource.apply(snapshot, to: .groups, animatingDifferences: animated)
    }
    if sections.contains(.workspaces) {
      var snapshot = NSDiffableDataSourceSectionSnapshot<HomeListItem>()
      append(model.loose, under: nil, to: &snapshot)
      dataSource.apply(snapshot, to: .workspaces, animatingDifferences: animated)
    }
    // Titles, states and counts change in place.
    var all = dataSource.snapshot()
    all.reconfigureItems(all.itemIdentifiers)
    dataSource.apply(all, animatingDifferences: false)
    syncSelection()
  }

  private func append(
    _ rows: [AgentSidebarRow], under parent: HomeListItem?,
    to snapshot: inout NSDiffableDataSourceSectionSnapshot<HomeListItem>
  ) {
    snapshot.append(rows.map { .workspace($0.id) }, to: parent)
    for row in rows where !row.children.isEmpty {
      append(row.children, under: .workspace(row.id), to: &snapshot)
      if list?.expandedWorkspaces.contains(row.id) == true { snapshot.expand([.workspace(row.id)]) }
    }
  }

  private func syncSelection() {
    guard isSelectionList else { return }
    let selected = collectionView.indexPathsForSelectedItems?.first.flatMap(dataSource.itemIdentifier)
    let wanted = list?.selection.map(HomeListItem.workspace)
    guard selected != wanted else { return }
    if let wanted, let indexPath = dataSource.indexPath(for: wanted) {
      collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
    } else if let indexPath = collectionView.indexPathsForSelectedItems?.first {
      collectionView.deselectItem(at: indexPath, animated: false)
    }
  }

  // MARK: - Selection and menus

  func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
    if case .workspace = dataSource.itemIdentifier(for: indexPath) { return true }
    return false
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    guard case let .workspace(id) = dataSource.itemIdentifier(for: indexPath),
      let row = model.placements[id]?.row
    else { return }
    if isSelectionList {
      list?.actions.select(id)
    } else {
      collectionView.deselectItem(at: indexPath, animated: true)
      list?.actions.open(row)
    }
  }

  func collectionView(
    _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard let indexPath = indexPaths.first, let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
    let menu: UIMenu?
    switch item {
    case let .workspace(id):
      guard let placement = model.placements[id] else { return nil }
      menu = list?.actions.workspaceMenu(placement.row, placement.owner.flatMap { model.placements[$0]?.row })
    case let .group(id):
      menu = model.group(id).flatMap(folderMenu)
    }
    guard let menu else { return nil }
    return UIContextMenuConfiguration(actionProvider: { _ in menu })
  }

  private func folderMenu(_ group: HomeSidebarGroup) -> UIMenu? {
    guard group.folder != nil else { return nil }
    return UIMenu(children: [
      UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { [weak self] _ in
        self?.list?.actions.renameGroup(group)
      },
      UIAction(title: "Delete Folder…", image: UIImage(systemName: "trash"), attributes: .destructive) {
        [weak self] _ in self?.confirmDelete(group)
      },
    ])
  }

  /// Asks before deleting a folder, from its row: the folder alone, or
  /// with the workspaces filed in it.
  private func confirmDelete(_ group: HomeSidebarGroup) {
    guard let folder = group.folder else { return }
    let sheet = UIAlertController(title: "Delete “\(folder.name)”?", message: nil, preferredStyle: .actionSheet)
    sheet.addAction(
      UIAlertAction(title: "Delete Folder", style: .default) { [weak self] _ in
        self?.list?.actions.deleteGroup(group, false)
      })
    let count = group.rows.count
    if count > 0 {
      sheet.addAction(
        UIAlertAction(title: "Delete Folder and \(count) Workspace\(count == 1 ? "" : "s")", style: .destructive) {
          [weak self] _ in self?.list?.actions.deleteGroup(group, true)
        })
    }
    sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    if let indexPath = dataSource.indexPath(for: .group(group.id)), let cell = collectionView.cellForItem(at: indexPath)
    {
      sheet.popoverPresentationController?.sourceView = cell
      sheet.popoverPresentationController?.sourceRect = cell.bounds
    }
    present(sheet, animated: true)
  }

  // MARK: - Drag and drop

  func collectionView(
    _ collectionView: UICollectionView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath
  ) -> [UIDragItem] {
    guard let item = dataSource.itemIdentifier(for: indexPath) else { return [] }
    let dragItem = UIDragItem(itemProvider: NSItemProvider())
    dragItem.localObject = item
    return [dragItem]
  }

  func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
    session.localDragSession?.items.first?.localObject is HomeListItem
  }

  func collectionView(
    _ collectionView: UICollectionView, dropSessionDidUpdate session: UIDropSession,
    withDestinationIndexPath destinationIndexPath: IndexPath?
  ) -> UICollectionViewDropProposal {
    guard let (drop, _) = target(for: session, at: destinationIndexPath) else {
      return UICollectionViewDropProposal(operation: .forbidden)
    }
    if case .intoGroup = drop {
      return UICollectionViewDropProposal(operation: .move, intent: .insertIntoDestinationIndexPath)
    }
    return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
  }

  func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator)
  {
    guard let dragItem = coordinator.items.first?.dragItem, let dragged = dragItem.localObject as? HomeListItem,
      let (drop, hovered) = target(for: coordinator.session, at: coordinator.destinationIndexPath)
    else { return }
    list?.actions.drop(dragged, drop)
    if case .intoGroup = drop, let hovered, let cell = collectionView.cellForItem(at: hovered) {
      coordinator.drop(dragItem, intoItemAt: hovered, rect: cell.bounds)
      reload(animated: true)
      return
    }
    // Shown where the store now has it, then the dragged row settles there.
    reload(animated: true)
    if let indexPath = dataSource.indexPath(for: dragged) {
      coordinator.drop(dragItem, toItemAt: indexPath)
    }
  }

  /// Where the session would drop: onto a folder's row when it's over the
  /// row's middle, else between rows at `indexPath`.
  private func target(for session: UIDropSession, at indexPath: IndexPath?) -> (HomeListDrop, IndexPath?)? {
    guard let dragged = session.localDragSession?.items.first?.localObject as? HomeListItem else { return nil }
    let location = session.location(in: collectionView)
    if let hovered = collectionView.indexPathForItem(at: location),
      let item = dataSource.itemIdentifier(for: hovered),
      let frame = collectionView.layoutAttributesForItem(at: hovered)?.frame,
      frame.insetBy(dx: 0, dy: frame.height * 0.2).contains(location),
      let drop = HomeListDrop.onto(item, dragging: dragged, model: model)
    {
      return (drop, hovered)
    }
    // Past a list's last row there's no index path: the end of that list.
    guard let indexPath = indexPath ?? end(above: location) else { return nil }
    let sections = dataSource.snapshot().sectionIdentifiers
    guard sections.indices.contains(indexPath.section) else { return nil }
    let section = sections[indexPath.section]
    let visible = dataSource.snapshot(for: section).visibleItems.filter { !model.isWithin($0, dragged) }
    return HomeListDrop.resolve(dragged, in: section, visible: visible, at: indexPath.item, model: model)
      .map { ($0, nil) }
  }
}

extension HomeAgentCollectionController {
  /// The end of the last list that starts above `location`.
  fileprivate func end(above location: CGPoint) -> IndexPath? {
    let sections = (0..<collectionView.numberOfSections).filter { section in
      collectionView.numberOfItems(inSection: section) > 0
        && (collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: section))?.frame.minY ?? .infinity)
          <= location.y
    }
    guard let section = sections.last else { return nil }
    return IndexPath(item: collectionView.numberOfItems(inSection: section), section: section)
  }
}

/// A list cell that remembers whether its row was drawn selected.
final class HomeListCell: UICollectionViewListCell {
  var drawnSelected: Bool?
}

/// A workspace's row: its state, its name, and how many workspaces are
/// nested right under it, as Notes counts a folder's subfolders.
struct HomeListWorkspaceRow: View {
  let row: AgentSidebarRow
  var isSelected = false

  var body: some View {
    HStack(spacing: 10) {
      HomeAgentMark(status: row.status, harnessId: row.harnessId)
      Text(row.title).lineLimit(1)
      Spacer(minLength: 0)
      if !row.children.isEmpty {
        Text("\(row.children.count)").foregroundStyle(isSelected ? .primary : .secondary).monospacedDigit()
      }
    }
    .foregroundStyle(isSelected ? Color.white : Color.primary)
  }
}

/// A folder's (or project's) row: its name and how many workspaces it holds.
struct HomeListGroupRow: View {
  let group: HomeSidebarGroup

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "folder")
        .foregroundStyle(.secondary)
        .frame(width: 20)
      Text(group.title).lineLimit(1)
      Spacer(minLength: 0)
      if !group.rows.isEmpty {
        Text("\(group.rows.count)").foregroundStyle(.secondary).monospacedDigit()
      }
    }
  }
}
