import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import SwiftUI

/// A Settings ▸ Machines row for a machine reached through the cloud
/// account's relay: connectable like any other machine, with presence, cloud
/// account actions, and the TOFU "key changed" warning when the machine's
/// presented key conflicts with the pinned one (relay channels are cut off
/// until the user explicitly re-trusts it).
struct CloudMachineRowView: View {
    @Environment(\.theme) private var theme

    let machine: CodevisorMachine
    let presence: CloudMachine
    let isSelected: Bool
    let keyChanged: Bool
    let onConnect: () -> Void
    let onRename: () -> Void
    let onRemove: () -> Void
    let onTrustKey: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: EntitySystemSymbol.machine(machine))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(theme.textPrimary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(presence.name)
                        .fontWeight(.medium)
                    if isSelected {
                        Text("Connected")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.accent.opacity(0.15)))
                            .foregroundStyle(theme.textPrimary)
                    }
                }
                Text("Codevisor Cloud")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if keyChanged {
                Button(action: onTrustKey) {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .accessibilityHidden(true)
                        Text("Key Changed")
                            .font(.caption)
                    }
                    .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("This machine's encryption key changed — click to review")
            } else {
                HStack(spacing: 5) {
                    Circle()
                        .fill(presence.online ? theme.statusOK : Color.gray)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(presence.online ? "Online" : "Offline")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !isSelected {
                Button("Connect", action: onConnect)
                    .settingsActionTint(theme)
                    .controlSize(.small)
            }
            Menu {
                if keyChanged {
                    Button("Trust New Key…", action: onTrustKey)
                    Divider()
                }
                Button("Rename…", action: onRename)
                Divider()
                Button("Disconnect…", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .settingsActionTint(theme)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Machine actions")
            .accessibilityLabel("Actions for \(presence.name)")
        }
        .contextMenu {
            if keyChanged {
                Button("Trust New Key…", action: onTrustKey)
            }
            Button("Rename…", action: onRename)
            Button("Disconnect…", role: .destructive, action: onRemove)
        }
        .accessibilityElement(children: .combine)
    }
}
