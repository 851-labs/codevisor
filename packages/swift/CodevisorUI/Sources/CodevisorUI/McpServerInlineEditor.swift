import CodevisorCore
import SwiftUI

public struct McpServerInlineEditor<Secrets: View>: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var draft: McpServerDraft
  @State private var showsAdvanced = false
  private let server: ServerMcpServer
  private let callbackNote: String
  private let save: (UpdateMcpServerBody) async throws -> ServerMcpServer
  private let secretsEditor: McpSecretsEditorBuilder<Secrets>

  public init(
    server: ServerMcpServer, callbackNote: String,
    save: @escaping (UpdateMcpServerBody) async throws -> ServerMcpServer,
    @ViewBuilder secretsEditor: @escaping McpSecretsEditorBuilder<Secrets>
  ) {
    self.server = server
    self.callbackNote = callbackNote
    self.save = save
    self.secretsEditor = secretsEditor
    _draft = State(initialValue: McpServerDraft(server: server))
  }

  public var body: some View {
    Group {
      LabeledContent("Transport", value: draft.isHTTP ? "HTTP" : "Local command")
      McpCommitField(
        title: draft.isHTTP ? "Server URL" : "Command", text: $draft.location,
        prompt: draft.isHTTP ? "https://example.com/mcp" : "npx -y some-mcp-server",
        onCommit: { commit { await $0.commitLocation(using: $1) } })
      McpFieldError(message: draft.errors[.location])
      if draft.needsConsent { PluginConsentNotice(name: server.name) }
      if draft.isHTTP { authorizationRows }
      McpServerAdvancedDisclosure(
        draft: draft, isExpanded: $showsAdvanced, callbackNote: callbackNote, actions: actions,
        secretsEditor: secretsEditor)
    }
    .onChange(of: server) { _, updated in draft.refresh(from: updated) }
    .onChange(of: draft.awaitsBearerToken) { _, awaits in
      if awaits { showsAdvanced = true }
    }
  }

  @ViewBuilder
  private var authorizationRows: some View {
    Picker("Authorization", selection: authorization) {
      Text("None").tag("none")
      Text("Bearer Token").tag("bearer")
      Text("OAuth").tag("oauth")
    }
    McpFieldError(message: draft.errors[.authorization])
  }

  private var authorization: Binding<String> {
    Binding(
      get: { draft.authType },
      set: { type in
        draft.authType = type
        commit { await $0.selectAuthorization(type, using: $1) }
      })
  }

  private var actions: McpServerDraft.Actions {
    McpServerDraft.Actions(save: save, recordConsent: recordConsent)
  }

  private func commit(_ work: @escaping @MainActor (McpServerDraft, McpServerDraft.Actions) async -> Void) {
    let draft = draft
    let actions = actions
    Task { await work(draft, actions) }
  }

  private func recordConsent(_ location: CustomPluginLocation) async throws {
    let subject = PluginModerationSubject(custom: location, name: server.name)
    try await environment.pluginAccess.recordConsent(subject, metadata: PluginConsentMetadata(custom: subject))
  }
}

public extension McpServerInlineEditor where Secrets == McpSecretRows {
  init(
    server: ServerMcpServer, callbackNote: String,
    save: @escaping (UpdateMcpServerBody) async throws -> ServerMcpServer
  ) {
    self.init(server: server, callbackNote: callbackNote, save: save) { entries, _, onCommit in
      McpSecretRows(entries: entries, valuePrompt: "Value", onCommit: onCommit)
    }
  }
}
