import CodevisorCore
import SwiftUI

struct McpServerDetailHeader: View {
  let name: String
  let status: McpFleet.MachineStatus?

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: isConnected ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(
          isConnected
            ? AnyShapeStyle(.green)
            : AnyShapeStyle(.secondary)
        )
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(name).font(.headline)
        Text(statusLabel)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(.horizontal, 20)
    .padding(.top, 18)
  }

  private var isConnected: Bool {
    if case .ready = status { true } else { false }
  }

  private var statusLabel: String {
    guard let status else { return "Syncing…" }
    return status.rowStatus.reason ?? status.label
  }
}
