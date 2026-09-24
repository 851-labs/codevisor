import CodevisorCore
import SwiftUI

#if os(iOS)
  /// One MCP server on a compact-width list: what it is, how the fleet is
  /// doing with it, and a way in. No switch — the row is a navigation link,
  /// and a row that both navigates and toggles has no unambiguous tap.
  ///
  /// The status sits on its own line rather than trailing the name. Trailing
  /// it made the row's height depend on how long the name and status
  /// happened to be together: "Computer Use · 1 needs attention" wrapped to
  /// two lines while "Codevisor · On 2 machines" stayed on one, so three
  /// rows had two different heights for no reason a reader could see. A
  /// two-line row is the same height for every server, never truncates a
  /// name the user chose, and grows properly with Dynamic Type.
  struct McpCompactRow<Icon: View>: View {
    let entry: McpFleetEntry
    let rows: [McpFleet.MachineRow]
    let icon: Icon

    var body: some View {
      Label {
        VStack(alignment: .leading, spacing: 2) {
          Text(entry.name)
          HStack(spacing: 6) {
            // The text beside it already says this; a mark that also
            // announces itself makes VoiceOver read the state twice.
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

    /// How many machines have it on, or what is wrong — whichever the user
    /// needs to know first.
    private var summary: String {
      if !entry.isMachineScoped && !entry.enabled { return "Off" }
      let attention = rows.filter(\.status.rowStatus.needsAttention).count
      if attention > 0 { return "\(attention) need\(attention == 1 ? "s" : "") attention" }
      let on = rows.filter(\.status.isOnHere).count
      if on == 0 { return "Off everywhere" }
      return on == rows.count ? "On \(on) machines" : "On \(on) of \(rows.count)"
    }

    /// The most urgent machine's status, so the mark reflects the fleet.
    private var worst: FleetRowStatus {
      if let attention = rows.first(where: \.status.rowStatus.needsAttention) {
        return attention.status.rowStatus
      }
      if let busy = rows.first(where: \.status.rowStatus.isBusy) { return busy.status.rowStatus }
      return .quiet("")
    }
  }
#endif
