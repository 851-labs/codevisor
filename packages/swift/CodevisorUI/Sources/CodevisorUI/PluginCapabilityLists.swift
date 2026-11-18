import CodevisorCore

public struct PluginCapabilityLists: Equatable, Sendable {
  private let tools: [PluginCapabilityItem]
  private let skills: [PluginCapabilityItem]
  private let events: [PluginCapabilityItem]
  private let panes: [PluginCapabilityItem]

  public init(capabilities: ServerPluginCapabilities) {
    tools = capabilities.tools.map {
      PluginCapabilityItem(id: $0.id, name: $0.name, detail: $0.description, isApp: $0.app == true)
    }
    skills = capabilities.skills.map { PluginCapabilityItem(id: $0.id, name: $0.name, detail: $0.description) }
    events = capabilities.events.map { PluginCapabilityItem(id: $0.id, name: $0.name, detail: $0.description) }
    panes = capabilities.panes.map { PluginCapabilityItem(id: $0.id, name: $0.title, detail: nil) }
  }

  public init(tools: [ServerMcpTool]) {
    self.tools = tools.map { PluginCapabilityItem(id: $0.id, name: $0.title ?? $0.name, detail: $0.description) }
    skills = []
    events = []
    panes = []
  }

  public var summaries: [PluginListSummary] {
    [PluginListPage.tools, .skills, .events, .panes]
      .map { PluginListSummary(page: $0, count: items(for: $0).count) }
      .filter { $0.count > 0 }
  }

  func items(for page: PluginListPage) -> [PluginCapabilityItem] {
    switch page {
    case .tools: tools
    case .skills: skills
    case .events: events
    case .panes: panes
    case .automations: []
    }
  }
}
