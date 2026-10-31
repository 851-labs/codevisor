import CodevisorCore
import Foundation

public enum WorkspaceSectionPlacement: Hashable, Sendable {
  case section(UUID)
  case unsectioned

  public static let unsectionedHeadingID = "list"

  public init?(_ row: SidebarRow) {
    guard row.parentID == nil, case let .workspace(_, placement) = row.kind else { return nil }

    switch placement {
    case let .custom(id): self = .section(id)
    case .group: self = .unsectioned
    case .pinned, .archived: return nil
    }
  }

  public init?(_ row: SidebarRow, membership: [UUID: UUID]) {
    guard row.parentID == nil, case let .workspace(item, .pinned) = row.kind else {
      self.init(row)
      return
    }

    self = membership[item.id].map(Self.section) ?? .unsectioned
  }

  public var sectionID: UUID? {
    switch self {
    case let .section(id): id
    case .unsectioned: nil
    }
  }

  public var headingID: String {
    switch self {
    case let .section(id): SidebarWorkspaceGroup.customSectionID(id)
    case .unsectioned: Self.unsectionedHeadingID
    }
  }
}
