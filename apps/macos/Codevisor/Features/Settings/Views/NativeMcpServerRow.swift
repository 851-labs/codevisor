import AppKit
import CodevisorCore
import SwiftUI
import CodevisorUI

/// One discovered server inside a harness's own config file: name, badges,
/// the harness-native enable toggle, and the more-actions menu.
struct NativeMcpServerRow: View {
    @Environment(\.theme) private var theme
    let server: ServerNativeMcpServer
    let setEnabled: (Bool) async -> Void
    let showDetails: () -> Void
    let requestRemoval: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: server.transport == "http" ? "globe" : "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.serverName).foregroundStyle(.primary)
                    if server.scope == "project" {
                        nativeBadge("Project")
                    }
                    if server.enabled == false {
                        nativeBadge("Disabled")
                    }
                    if server.alreadyManaged {
                        nativeBadge("In Codevisor")
                    }
                }
                Text(server.identity)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if server.supportsDisable {
                Toggle(
                    "Enable \(server.serverName) in \(server.harnessName)",
                    isOn: Binding(
                        get: { server.enabled ?? true },
                        set: { enabled in Task { await setEnabled(enabled) } }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            Menu {
                Button("Show Details…") { showDetails() }
                if FileManager.default.fileExists(atPath: server.configPath) {
                    Button("Reveal Config in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: server.configPath)]
                        )
                    }
                }
                if server.supportsRemove {
                    Divider()
                    Button("Remove from \(server.harnessName)…", role: .destructive) {
                        requestRemoval()
                    }
                }
            } label: {
                Label("More actions for \(server.serverName)", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .settingsActionTint(theme)
            .menuIndicator(.hidden)
            .help("More Actions")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(server.serverName), installed in \(server.harnessName)")
    }

    private func nativeBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(theme.isSystem ? AnyShapeStyle(.quaternary) : AnyShapeStyle(theme.cardQuietBackground))
            )
            .foregroundStyle(.secondary)
    }
}
