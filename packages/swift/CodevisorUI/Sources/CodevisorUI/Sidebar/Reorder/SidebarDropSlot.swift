import Foundation

public struct SidebarDropSlot<RowID: Hashable>: Equatable {
  public enum Kind: Equatable {
    case header(section: UUID?)
    case item(UUID, section: UUID?)
  }

  public let row: RowID
  public let kind: Kind
  public let rows: [RowID]

  public init(row: RowID, kind: Kind, rows: [RowID]? = nil) {
    self.row = row
    self.kind = kind
    self.rows = rows ?? [row]
  }

  public static func header(_ row: RowID, section: UUID?) -> Self {
    Self(row: row, kind: .header(section: section))
  }

  public static func item(_ id: UUID, row: RowID, section: UUID?, rows: [RowID]? = nil) -> Self {
    Self(row: row, kind: .item(id, section: section), rows: rows)
  }

  public var itemID: UUID? {
    guard case let .item(id, _) = kind else { return nil }
    return id
  }

  public var section: UUID? {
    switch kind {
    case let .header(section), let .item(_, section): section
    }
  }

  public var isHeader: Bool { itemID == nil }
}
