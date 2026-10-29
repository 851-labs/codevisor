import CodevisorCore
import SwiftUI

struct McpMachineTrailing: View {
  @Environment(AppEnvironment.self) private var environment
  let entry: McpFleetEntry
  let row: McpFleet.MachineRow
  let model: McpGlobalModel
  let disabledReason: String?

  var body: some View {
    #if os(macOS)
      if entry.kind == "browserUse" {
        McpBrowserExtensionInstallButton(machineId: row.machineId, model: model)
      }
    #endif
    Toggle("Available on \(row.name)", isOn: availability)
      .labelsHidden().toggleStyle(.switch)
      .disabled(isLocked)
      .help(disabledReason ?? "")
      #if os(macOS)
        .controlSize(.mini)
      #endif
  }

  private var isLocked: Bool {
    row.status == .unreachable || (!row.isOn && disabledReason != nil)
  }

  private var availability: Binding<Bool> {
    Binding(
      get: { row.isOn },
      set: { next in
        Task { await model.setAvailability(next, of: entry, on: row.machineId, in: environment) }
      })
  }
}
