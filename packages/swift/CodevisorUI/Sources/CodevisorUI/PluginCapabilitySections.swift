import CodevisorCore
import SwiftUI

public struct PluginCapabilitySections: View {
  let capabilities: ServerPluginCapabilities

  public init(capabilities: ServerPluginCapabilities) {
    self.capabilities = capabilities
  }

  public var body: some View {
    if !capabilities.tools.isEmpty {
      PluginListDisclosure("Tools", count: capabilities.tools.count) {
        ForEach(capabilities.tools) { tool in
          PluginCapabilityRow(name: tool.name, detail: tool.description, isApp: tool.app == true)
        }
      }
    }
    if !capabilities.events.isEmpty {
      PluginListDisclosure("Events", count: capabilities.events.count) {
        ForEach(capabilities.events) { PluginCapabilityRow(name: $0.name, detail: $0.description) }
      }
    }
    if !capabilities.skills.isEmpty {
      PluginListDisclosure("Skills", count: capabilities.skills.count) {
        ForEach(capabilities.skills) { PluginCapabilityRow(name: $0.name, detail: $0.description) }
      }
    }
    if !capabilities.panes.isEmpty {
      PluginListDisclosure("Panes", count: capabilities.panes.count) {
        ForEach(capabilities.panes) { PluginCapabilityRow(name: $0.title, detail: nil) }
      }
    }
  }
}
