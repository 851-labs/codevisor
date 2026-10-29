import CodevisorCore
import SwiftUI

public struct McpFleetEntryLabel<Icon: View>: View {
  @Environment(AppEnvironment.self) private var environment
  private let entry: McpFleetEntry
  private let model: McpGlobalModel
  private let icon: Icon

  public init(entry: McpFleetEntry, model: McpGlobalModel, @ViewBuilder icon: () -> Icon) {
    self.entry = entry
    self.model = model
    self.icon = icon()
  }

  public var body: some View {
    #if os(iOS)
      Label {
        title
      } icon: {
        icon.accessibilityHidden(true)
      }
    #else
      HStack(spacing: 10) {
        icon.frame(width: 22).accessibilityHidden(true)
        title
      }
      .frame(minHeight: FleetRowMetrics.minContentHeight)
      .padding(.vertical, 2)
    #endif
  }

  private var title: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(entry.name).lineLimit(1)
      Text(summary.label)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }

  private var summary: McpFleetSummary {
    McpFleetSummary(entry: entry, rows: model.rows(for: entry, in: environment))
  }
}
