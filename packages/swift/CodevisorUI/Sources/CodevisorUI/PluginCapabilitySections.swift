import CodevisorCore
import SwiftUI

public struct PluginCapabilitySections: View {
  let capabilities: ServerPluginCapabilities

  public init(capabilities: ServerPluginCapabilities) {
    self.capabilities = capabilities
  }

  public var body: some View {
    if !capabilities.tools.isEmpty {
      PluginToolsDisclosure(count: capabilities.tools.count) {
        ForEach(capabilities.tools) { tool in
          PluginCapabilityRow(name: tool.name, detail: tool.description, isApp: tool.app == true)
        }
      }
    }
    if !capabilities.events.isEmpty {
      Section("Events") {
        ForEach(capabilities.events) { PluginCapabilityRow(name: $0.name, detail: $0.description) }
      }
    }
    if !capabilities.skills.isEmpty {
      Section("Skills") {
        ForEach(capabilities.skills) { PluginCapabilityRow(name: $0.name, detail: $0.description) }
      }
    }
    if !capabilities.panes.isEmpty {
      Section("Panes") {
        ForEach(capabilities.panes) { PluginCapabilityRow(name: $0.title, detail: nil) }
      }
    }
  }
}
