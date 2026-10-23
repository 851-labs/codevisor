import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import SwiftUI

struct CloudMachineRowView: View {
  let machine: CodevisorMachine
  let presence: CloudMachine
  let keyChanged: Bool
  let connection: MachineConnectionPresentation
  let onEdit: () -> Void
  let onRemove: () -> Void
  let onTrustKey: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: machine.icon.systemImage)
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(.primary)
        .frame(width: 20)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(presence.name)
        Text("Codevisor Cloud")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 12)
      if keyChanged {
        Button(action: onTrustKey) {
          HStack(spacing: 5) {
            Image(systemName: "exclamationmark.shield.fill")
              .accessibilityHidden(true)
            Text("Key Changed")
              .font(.callout)
          }
          .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
        .help("This machine's encryption key changed — click to review")
      } else {
        MachineConnectionBadge(connection)
      }
      Menu {
        if keyChanged {
          Button("Trust New Key…", action: onTrustKey)
          Divider()
        }
        Button("Edit…", action: onEdit)
        Divider()
        Button("Disconnect…", role: .destructive, action: onRemove)
      } label: {
        Image(systemName: "ellipsis.circle")
          .foregroundStyle(.secondary)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Machine actions")
      .accessibilityLabel("Actions for \(presence.name)")
    }
    .contextMenu {
      if keyChanged {
        Button("Trust New Key…", action: onTrustKey)
      }
      Button("Edit…", action: onEdit)
      Button("Disconnect…", role: .destructive, action: onRemove)
    }
    .accessibilityElement(children: .combine)
  }
}
