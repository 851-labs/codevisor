import UIKit

struct HomeSidebarCollectionSnapshots {
  typealias Row = HomeSidebarCollectionRow
  typealias Snapshot = NSDiffableDataSourceSectionSnapshot<Row.ID>

  let outline: Snapshot
  let archived: Snapshot

  init(rows: [Row], appearance: HomeSidebarCollection.Appearance, collapsedSection: UUID?) {
    let shown = rows.filter { collapsedSection == nil || $0.member != collapsedSection }
    outline = Self.flat(shown.filter { $0.section == .outline }.map(\.id))
    let archivedRows = shown.filter { $0.section == .archived }.map(\.id)
    archived = Self.flat(appearance.isConversation ? archivedRows.filter { $0 != .archivedHeader } : archivedRows)
  }

  private static func flat(_ ids: [Row.ID]) -> Snapshot {
    var snapshot = Snapshot()
    snapshot.append(ids)
    return snapshot
  }
}
