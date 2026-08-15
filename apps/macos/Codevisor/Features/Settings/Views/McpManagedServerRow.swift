import CodevisorCore
import CodevisorCoreMac
import SwiftUI
import CodevisorUI

/// A managed (or built-in) MCP server row: status glyph and text, the
/// Browser Use browser picker, the enable toggle or OAuth Connect button,
/// the more-actions menu, and — for Computer Use — the inline permission
/// setup rows beneath it.
struct McpManagedServerRow: View {
    @Environment(\.theme) private var theme
    let server: ServerMcpServer
    let browserConfiguration: ServerBrowserUseConfiguration?
    let computerPermissions: ComputerUsePermissionsModel
    let setPreferredBrowser: (String) async -> Void
    let installBrowserExtension: () async -> Void
    let beginOAuth: () async throws -> Void
    let setEnabled: (Bool) async -> Void
    let showDetails: () -> Void
    let edit: () -> Void
    let requestRemoval: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rowContent
            if server.kind == "computerUse" {
                // Always visible, in every state: these rows are the live
                // status of what Computer Use depends on, and they carry the
                // poll that notices a permission revoked in System Settings.
                ComputerUsePermissionRowsView(model: computerPermissions, embedded: true)
                    .padding(.leading, 30)
                    .onChange(of: computerPermissions.allGranted) { _, granted in
                        // Revoked underneath a running Computer Use: turn it
                        // off so the row never claims to work when it can't.
                        guard !granted, server.enabled else { return }
                        Task { await setEnabled(false) }
                    }
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol(server))
                .foregroundStyle(statusStyle(server))
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                // No "Built-in" badge here: built-ins live in their own
                // labeled section.
                Text(server.name).foregroundStyle(.primary)
                Text(statusText(server))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if server.kind == "browserUse", let browserConfiguration {
                Menu {
                    // Remote machines never offer Chrome: the extension
                    // handshake needs someone at that machine's desktop, so
                    // Browser Use always runs the managed browser there.
                    if browserConfiguration.chromeAvailable,
                        browserConfiguration.supportsExtensionFlow
                    {
                        Button {
                            Task { await setPreferredBrowser("chrome") }
                        } label: {
                            if browserConfiguration.preferredBrowser == "chrome" {
                                Label("Google Chrome", systemImage: "checkmark")
                            } else {
                                Text("Google Chrome")
                            }
                        }
                    }
                    Button {
                        Task { await setPreferredBrowser("managed") }
                    } label: {
                        if browserConfiguration.preferredBrowser == "managed" {
                            Label("Codevisor Browser", systemImage: "checkmark")
                        } else {
                            Text("Codevisor Browser")
                        }
                    }
                    if browserConfiguration.chromeAvailable,
                        browserConfiguration.supportsExtensionFlow,
                        !browserConfiguration.chromeConnected,
                        browserConfiguration.developmentExtensionPath != nil
                    {
                        Divider()
                        Button("Install Chrome Extension…") {
                            Task { await installBrowserExtension() }
                        }
                    }
                } label: {
                    Text(preferredBrowserLabel(browserConfiguration))
                }
                .controlSize(.small)
                .settingsActionTint(theme)
            }
            let needsAuthorization =
                server.authType == "oauth"
                && ["needsAuthorization", "expired", "error"].contains(server.connectionState)
            if needsAuthorization {
                Button("Connect…") {
                    Task { try? await beginOAuth() }
                }
                .settingsActionTint(theme)
                .controlSize(.small)
            } else {
                Toggle(
                    "Enable \(server.name)",
                    isOn: Binding(
                        get: { server.enabled },
                        set: { enabled in Task { await setEnabled(enabled) } }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                // Computer Use can't turn on without its permissions; the
                // rows right below unlock this. Turning it off stays allowed.
                .disabled(
                    server.kind == "computerUse"
                        && !server.enabled
                        && !computerPermissions.allGranted
                )
            }
            Menu {
                Button("Show Details…") { showDetails() }
                if server.canEdit != false {
                    Button("Edit…") { edit() }
                }
                if server.canRemove != false {
                    Divider()
                    Button("Remove…", role: .destructive) { requestRemoval() }
                }
            } label: {
                Label("More actions for \(server.name)", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .settingsActionTint(theme)
            .menuIndicator(.hidden)
            .help("More Actions")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(server.name), \(statusText(server)), \(server.enabled ? "enabled" : "disabled")")
    }

    private func statusText(_ server: ServerMcpServer) -> String {
        if server.authType == "oauth",
            ["needsAuthorization", "expired", "error"].contains(server.connectionState)
        {
            return "Not connected"
        }
        switch server.connectionState {
        case "connected": return "Connected · \(server.toolCount) tool\(server.toolCount == 1 ? "" : "s")"
        case "connecting": return "Connecting…"
        case "needsSetup": return server.detail ?? "Browser setup required"
        case "unavailable": return server.detail ?? "Unavailable on this machine"
        case "needsAuthorization": return "Authorization required"
        case "expired": return "Sign-in expired"
        case "error": return server.detail ?? "Connection failed"
        default: return server.enabled ? "Not connected" : "Disabled"
        }
    }

    private func statusSymbol(_ server: ServerMcpServer) -> String {
        if server.authType == "oauth",
            ["needsAuthorization", "expired", "error"].contains(server.connectionState)
        {
            return "circle"
        }
        switch server.connectionState {
        case "connected": return "checkmark.circle.fill"
        case "connecting": return "arrow.triangle.2.circlepath"
        case "needsSetup": return "arrow.down.circle"
        case "unavailable": return "nosign"
        case "needsAuthorization", "expired": return "person.crop.circle.badge.exclamationmark"
        case "error": return "exclamationmark.triangle.fill"
        default: return "circle"
        }
    }

    private func statusStyle(_ server: ServerMcpServer) -> AnyShapeStyle {
        if server.authType == "oauth",
            ["needsAuthorization", "expired", "error"].contains(server.connectionState)
        {
            return AnyShapeStyle(.secondary)
        }
        switch server.connectionState {
        case "connected": return AnyShapeStyle(theme.statusOK)
        case "needsAuthorization", "expired", "needsSetup": return AnyShapeStyle(theme.statusWarn)
        case "error": return AnyShapeStyle(theme.statusError)
        default: return AnyShapeStyle(.secondary)
        }
    }

    private func preferredBrowserLabel(_ configuration: ServerBrowserUseConfiguration) -> String {
        // Whatever an old preference says, a server without the extension
        // flow always runs the managed browser.
        if !configuration.supportsExtensionFlow { return "Codevisor Browser" }
        switch configuration.preferredBrowser {
        case "chrome": return configuration.chromeConnected ? "Chrome" : "Chrome · Setup"
        case "managed": return "Codevisor Browser"
        default: return "Choose Browser"
        }
    }
}
