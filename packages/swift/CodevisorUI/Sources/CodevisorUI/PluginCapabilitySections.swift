import CodevisorCore
import SwiftUI

public struct PluginCapabilitySections: View {
  let capabilities: ServerPluginCapabilities

  public init(capabilities: ServerPluginCapabilities) {
    self.capabilities = capabilities
  }

  public var body: some View {
    if !capabilities.tools.isEmpty {
      Section("Tools") {
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

private struct PluginCapabilityRow: View {
  let name: String
  let detail: String?
  var isApp = false

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Text(name)
        if isApp {
          Text("App")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .background(.quaternary, in: Capsule())
        }
      }
      if let detail {
        Text(detail).font(.callout).foregroundStyle(.secondary)
      }
    }
  }
}
