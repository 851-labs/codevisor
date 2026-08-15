import AppKit
import CodevisorCore
import SwiftUI
import CodevisorUI

/// Read-only detail for an MCP server that lives in a harness's own config
/// file. Secret values never reach the client, so env vars and headers render
/// as names only.
struct NativeMcpDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let server: ServerNativeMcpServer

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: server.transport == "http" ? "globe" : "terminal")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.serverName).font(.headline)
                    Text("Installed in \(server.harnessName)\(server.scope == "project" ? " · Project" : "")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            Form {
                Section("Connection") {
                    LabeledContent("Transport", value: server.transport == "http" ? "HTTP" : "Local command")
                    if let url = server.url {
                        LabeledContent("Server URL") {
                            Text(url).textSelection(.enabled)
                        }
                    }
                    if let command = server.command {
                        LabeledContent("Command") {
                            Text(([command] + server.args).joined(separator: " "))
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    if let enabled = server.enabled {
                        LabeledContent("Enabled in \(server.harnessName)", value: enabled ? "Yes" : "No")
                    }
                }
                .listRowBackground(themedFormRowBackground)
                if !server.headerNames.isEmpty || !server.envNames.isEmpty {
                    Section("Secrets") {
                        if !server.headerNames.isEmpty {
                            LabeledContent("HTTP Headers", value: server.headerNames.joined(separator: ", "))
                        }
                        if !server.envNames.isEmpty {
                            LabeledContent("Environment Variables", value: server.envNames.joined(separator: ", "))
                        }
                        Text("Values stay in the harness's config file and are never read into Codevisor.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(themedFormRowBackground)
                }
                Section("Source") {
                    LabeledContent("Config File") {
                        Text(server.configPath)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                .listRowBackground(themedFormRowBackground)
            }
            .formStyle(.grouped)
            .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
            Divider()
                .overlay(theme.isSystem ? Color.clear : theme.separator)
            HStack {
                if FileManager.default.fileExists(atPath: server.configPath) {
                    Button("Reveal Config in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: server.configPath)]
                        )
                    }
                    .settingsActionTint(theme)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .settingsActionTint(theme)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            .themedSurface(.sheet)
        }
        .frame(width: 540, height: 420)
        .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
        .themedSurface(.sheet)
    }

    private var themedFormRowBackground: Color? {
        theme.isSystem ? nil : theme.cardQuietBackground
    }
}
