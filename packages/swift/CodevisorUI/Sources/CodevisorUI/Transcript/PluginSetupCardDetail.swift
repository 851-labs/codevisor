import CodevisorCore
import SwiftUI

struct PluginSetupCardDetail: View {
  let request: ServerPluginSetupRequest

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(caption)
        .font(.caption)
        .foregroundStyle(.secondary)
      if !request.capabilities.isEmpty {
        PluginCapabilityChips(capabilities: request.capabilities)
      }
    }
  }

  private var caption: String {
    [request.publisher, request.machine.name].compactMap(\.self).joined(separator: " · ")
  }
}
