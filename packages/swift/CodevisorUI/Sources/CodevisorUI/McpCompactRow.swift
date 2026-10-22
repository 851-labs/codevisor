import CodevisorCore
import SwiftUI

#if os(iOS)
  struct McpCompactRow<Icon: View>: View {
    let entry: McpFleetEntry
    let rows: [McpFleet.MachineRow]
    let icon: Icon

    var body: some View {
      Label {
        VStack(alignment: .leading, spacing: 2) {
          Text(entry.name)
          HStack(spacing: 6) {
            FleetStatusMark(status: worst)
              .accessibilityHidden(true)
            Text(summary)
          }
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
      } icon: {
        icon.accessibilityHidden(true)
      }
    }

    private var summary: String {
      let attention = rows.filter(\.status.rowStatus.needsAttention).count
      if attention > 0 { return "\(attention) need\(attention == 1 ? "s" : "") attention" }
      let on = rows.filter(\.isOn).count
      if on == 0 { return "Off" }
      return on == rows.count ? "On \(on) machines" : "On \(on) of \(rows.count)"
    }

    private var worst: FleetRowStatus {
      if let attention = rows.first(where: \.status.rowStatus.needsAttention) {
        return attention.status.rowStatus
      }
      if let busy = rows.first(where: \.status.rowStatus.isBusy) { return busy.status.rowStatus }
      return .quiet("")
    }
  }
#endif
