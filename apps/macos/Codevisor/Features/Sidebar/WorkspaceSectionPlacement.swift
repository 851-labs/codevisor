import CodevisorCore
import CodevisorUI
import Foundation

enum WorkspaceSectionPlacement: Hashable {
  case section(UUID)
  case unsectioned

  static let unsectionedHeadingID = "list"

  init?(_ row: SidebarRow) {
    guard row.parentID == nil, case let .workspace(_, placement) = row.kind else { return nil }

    switch placement {
    case let .custom(id): self = .section(id)
    case .group: self = .unsectioned
    case .pinned, .archived: return nil
    }
  }

  var sectionID: UUID? {
    switch self {
    case let .section(id): id
    case .unsectioned: nil
    }
  }

  var headingID: String {
    switch self {
    case let .section(id): SidebarWorkspaceGroup.customSectionID(id)
    case .unsectioned: Self.unsectionedHeadingID
    }
  }
}
