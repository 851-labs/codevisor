import CodevisorCore
import SwiftUI

public struct PluginCapabilityChips: View {
  let capabilities: ServerPluginCapabilities

  public init(capabilities: ServerPluginCapabilities) {
    self.capabilities = capabilities
  }

  public var body: some View {
    HStack(spacing: 6) {
      ForEach(PluginCapabilityCount.counts(in: capabilities)) { count in
        Label(count.title, systemImage: count.systemImage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 7)
          .padding(.vertical, 2)
          .background(.quaternary, in: Capsule())
      }
    }
  }
}
