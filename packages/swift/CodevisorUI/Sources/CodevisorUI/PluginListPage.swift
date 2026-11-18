public enum PluginListPage: String, Hashable, Sendable {
  case automations
  case tools
  case skills
  case events
  case panes

  public var title: String {
    switch self {
    case .automations: "Automations"
    case .tools: "Tools"
    case .skills: "Skills"
    case .events: "Events"
    case .panes: "Panes"
    }
  }
}
