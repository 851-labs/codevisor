import CodevisorCore
import Foundation

public enum SectionPrompt: Identifiable, Equatable, Sendable {
  case create(moving: UUID?)
  case rename(CustomSection)

  public var id: String {
    switch self {
    case .create: "create"
    case let .rename(section): "rename:\(section.id)"
    }
  }

  public var title: String {
    switch self {
    case .create: "New Section"
    case .rename: "Rename Section"
    }
  }

  public var confirmTitle: String {
    switch self {
    case .create: "Create"
    case .rename: "Rename"
    }
  }

  public var initialName: String {
    switch self {
    case .create: ""
    case let .rename(section): section.name
    }
  }
}
