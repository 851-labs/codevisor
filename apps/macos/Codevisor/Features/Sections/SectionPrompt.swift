import CodevisorCore

enum SectionPrompt: Identifiable {
  case create(moving: UUID?)
  case rename(CustomSection)

  var id: String {
    switch self {
    case .create: "create"
    case let .rename(section): "rename:\(section.id)"
    }
  }

  var title: String {
    switch self {
    case .create: "New Section"
    case .rename: "Rename Section"
    }
  }

  var confirmTitle: String {
    switch self {
    case .create: "Create"
    case .rename: "Rename"
    }
  }

  var initialName: String {
    switch self {
    case .create: ""
    case let .rename(section): section.name
    }
  }
}
