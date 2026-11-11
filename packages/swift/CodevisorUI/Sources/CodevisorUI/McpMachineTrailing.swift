#if os(macOS)
  import CodevisorCore
  import SwiftUI

  struct McpMachineTrailing: View {
    @Environment(AppEnvironment.self) private var environment
    let entry: McpFleetEntry
    let row: McpFleet.MachineRow
    let model: McpGlobalModel
    let disabledReason: String?

    var body: some View {
      if entry.kind == "browserUse" {
        McpBrowserExtensionInstallButton(machineId: row.machineId, model: model)
      }
      if !entry.isAlwaysOn {
        Toggle("Available on \(row.name)", isOn: availability)
          .labelsHidden().toggleStyle(.switch)
          .disabled(isLocked)
          .help(disabledReason ?? "")
          .controlSize(.mini)
      }
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
#endif
