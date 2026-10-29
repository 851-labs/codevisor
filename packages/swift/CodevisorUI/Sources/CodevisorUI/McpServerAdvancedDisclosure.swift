import CodevisorCore
import SwiftUI

public typealias McpSecretsEditorBuilder<Secrets: View> =
  (_ entries: Binding<[McpSecretEntry]>, _ isHTTP: Bool, _ onCommit: @escaping () -> Void) -> Secrets

struct McpServerAdvancedDisclosure<Secrets: View>: View {
  @Bindable var draft: McpServerDraft
  @Binding var isExpanded: Bool
  let callbackNote: String
  let actions: McpServerDraft.Actions
  let secretsEditor: McpSecretsEditorBuilder<Secrets>

  var body: some View {
    SettingsDisclosureRows(isExpanded: $isExpanded) {
      Text("Advanced").foregroundStyle(.primary)
    } content: {
      if draft.isHTTP && draft.authType == "bearer" { bearerRows }
      if draft.isHTTP && draft.authType == "oauth" { oauthRows }
      Text(draft.isHTTP ? "HTTP Headers" : "Environment Variables")
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
      secretsEditor($draft.secrets, draft.isHTTP) { commit { await $0.commitSecrets(using: $1) } }
      McpFieldError(message: draft.errors[.secrets])
    }
  }

  @ViewBuilder
  private var bearerRows: some View {
    McpCommitField(
      title: "Bearer Token", text: $draft.bearerToken,
      prompt: draft.server.authType == "bearer" ? "Saved — enter a new token to replace" : "Paste token",
      isSecure: true,
      onCommit: { commit { await $0.commitBearerToken(using: $1) } })
    McpFieldError(message: draft.errors[.bearerToken])
  }

  @ViewBuilder
  private var oauthRows: some View {
    McpCommitField(
      title: "Scopes", text: $draft.oauthScope, prompt: "org:read project:read",
      onCommit: { commit { await $0.commitOAuthScope(using: $1) } })
    McpFieldError(message: draft.errors[.oauthScope])
    McpCommitField(
      title: "Client ID", text: $draft.clientId, prompt: "Optional client ID",
      onCommit: { commit { await $0.commitOAuthClient(using: $1) } })
    McpCommitField(
      title: "Client Secret", text: $draft.clientSecret, prompt: "Optional client secret", isSecure: true,
      onCommit: { commit { await $0.commitOAuthClient(using: $1) } })
    McpFieldError(message: draft.errors[.oauthClient])
    Text(callbackNote)
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func commit(_ work: @escaping @MainActor (McpServerDraft, McpServerDraft.Actions) async -> Void) {
    let draft = draft
    let actions = actions
    Task { await work(draft, actions) }
  }
}
