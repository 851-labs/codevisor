import CodevisorCore
import SwiftUI
import CodevisorUI

struct McpServerEditorSheet: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss
  @Environment(\.theme) private var theme
  @Environment(\.settingsMachineId) private var settingsMachineId
  let initialServer: ServerMcpServer?
  let save: (McpFormValues) async throws -> Void
  @State private var name: String
  @State private var transport: String
  @State private var location: String
  @State private var authSelection: String
  @State private var detectedAuthType: String?
  @State private var isDetecting = false
  @State private var bearerToken: String
  @State private var oauthScope: String
  @State private var clientId = ""
  @State private var clientSecret = ""
  @State private var headerEntries: [McpSecretEntry]
  @State private var environmentEntries: [McpSecretEntry]
  @State private var isOAuthAdvancedExpanded = false
  @State private var isKeyValueEditorExpanded = false
  private let initialHeaderNames: Set<String>
  private let initialEnvironmentNames: Set<String>
  @State private var nameWasEdited: Bool
  @State private var isSaving = false
  @State private var errorMessage: String?

  init(
    initialServer: ServerMcpServer?,
    save: @escaping (McpFormValues) async throws -> Void
  ) {
    self.initialServer = initialServer
    self.save = save
    _name = State(initialValue: initialServer?.name ?? "")
    _transport = State(initialValue: initialServer?.transport ?? "http")
    _location = State(
      initialValue: initialServer?.url
        ?? CommandLineCodec.format(
          [initialServer?.command].compactMap { $0 } + (initialServer?.args ?? [])
        ))
    _authSelection = State(initialValue: initialServer?.authType ?? "auto")
    _detectedAuthType = State(initialValue: initialServer?.authType)
    _bearerToken = State(initialValue: "")
    _oauthScope = State(initialValue: initialServer?.oauthScope ?? "")
    _nameWasEdited = State(initialValue: initialServer != nil)
    let headerNames = Set(initialServer?.headerNames ?? [])
    let environmentNames = Set(initialServer?.environmentNames ?? [])
    initialHeaderNames = headerNames
    initialEnvironmentNames = environmentNames
    _headerEntries = State(
      initialValue: headerNames.sorted().map {
        McpSecretEntry(name: $0, value: "", existing: true)
      })
    _environmentEntries = State(
      initialValue: environmentNames.sorted().map {
        McpSecretEntry(name: $0, value: "", existing: true)
      })
  }

  var body: some View {
    VStack(spacing: 0) {
      Text(initialServer == nil ? "Add MCP Server" : "Edit MCP Server")
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 18)
      Form {
        Section("Connection") {
          if initialServer == nil {
            transportPicker
              .onChange(of: transport) { _, value in
                if value == "stdio" && authSelection == "oauth" {
                  authSelection = "auto"
                }
              }
          } else {
            LabeledContent(
              "Transport",
              value: transport == "http" ? "HTTP" : "STDIO"
            )
          }
          if transport == "http" {
            TextField(
              "Server URL",
              text: $location,
              prompt: Text(verbatim: "https://mcp.sentry.dev")
            )
            TextField(
              "Name",
              text: Binding(
                get: { name },
                set: {
                  name = $0; nameWasEdited = true
                }
              ), prompt: Text("Sentry"))
            authorizationPicker
            if effectiveAuthType == "bearer" {
              SecureField("Bearer Token", text: $bearerToken, prompt: Text("Paste token"))
            }
          } else {
            TextField(
              "Command",
              text: $location,
              prompt: Text("npx @playwright/mcp@latest")
            )
            TextField(
              "Name",
              text: Binding(
                get: { name },
                set: {
                  name = $0; nameWasEdited = true
                }
              ), prompt: Text("Playwright"))
          }
        }
        .listRowBackground(themedFormRowBackground)

        if effectiveAuthType == "oauth" {
          Section {
            SettingsDisclosureRow(
              "Advanced OAuth",
              isExpanded: $isOAuthAdvancedExpanded
            ) {
              VStack(spacing: 10) {
                TextField("Scopes", text: $oauthScope, prompt: Text("org:read project:read"))
                TextField("Client ID", text: $clientId, prompt: Text("Optional client ID"))
                SecureField(
                  "Client Secret",
                  text: $clientSecret,
                  prompt: Text("Optional client secret")
                )
              }
              .padding(.top, 8)
            }
          }
          .listRowBackground(themedFormRowBackground)
        }

        Section {
          SettingsDisclosureRow(
            transport == "http" ? "HTTP Headers" : "Environment Variables",
            isExpanded: $isKeyValueEditorExpanded
          ) {
            Group {
              if transport == "http" {
                McpKeyValueEditor(
                  entries: $headerEntries,
                  nameHeading: "Header",
                  namePrompt: "Authorization",
                  valuePrompt: "Bearer token",
                  emptyLabel: "No custom headers",
                  addLabel: "Add Header"
                )
              } else {
                McpKeyValueEditor(
                  entries: $environmentEntries,
                  nameHeading: "Variable",
                  namePrompt: "DEBUG",
                  valuePrompt: "pw:mcp",
                  emptyLabel: "No environment variables",
                  addLabel: "Add Environment Variable"
                )
              }
            }
            .padding(.top, 8)
          }
        }
        .listRowBackground(themedFormRowBackground)

        if let errorMessage {
          Section {
            Text(errorMessage)
              .foregroundStyle(theme.statusError)
              .font(.callout)
          }
          .listRowBackground(themedFormRowBackground)
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
      Divider()
        .overlay(theme.isSystem ? Color.clear : theme.separator)
      HStack {
        Spacer()
        cancelButton
        Button(initialServer == nil ? "Add" : "Save") { Task { await submit() } }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(!isValid || isSaving)
      }
      .padding()
      .themedSurface(.sheet)
    }
    .frame(width: 560, height: 570)
    .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
    .themedSurface(.sheet)
    .task(id: location) { await detectAuthorization() }
  }

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: settingsMachineId ?? environment.defaultComposerServerId)
  }

  private var effectiveAuthType: String {
    guard transport == "http" else { return "none" }
    return authSelection == "auto" ? (detectedAuthType ?? "none") : authSelection
  }

  private var themedFormRowBackground: Color? {
    theme.isSystem ? nil : theme.cardQuietBackground
  }

  @ViewBuilder
  private var transportPicker: some View {
    if theme.isSystem {
      Picker("Transport", selection: $transport) {
        Text("HTTP").tag("http")
        Text("STDIO").tag("stdio")
      }
      .pickerStyle(.segmented)
    } else {
      LabeledContent("Transport") {
        McpThemedTransportPicker(selection: $transport, theme: theme)
          .frame(width: 244)
      }
    }
  }

  @ViewBuilder
  private var authorizationPicker: some View {
    if theme.isSystem {
      Picker(selection: $authSelection) {
        Text(automaticAuthorizationLabel).tag("auto")
        Text("None").tag("none")
        Text("Bearer Token").tag("bearer")
        Text("OAuth").tag("oauth")
      } label: {
        authorizationLabel
      }
      .pickerStyle(.menu)
    } else {
      LabeledContent {
        McpThemedAuthorizationPicker(
          selection: $authSelection,
          automaticLabel: automaticAuthorizationLabel,
          theme: theme
        )
        .frame(width: 244)
      } label: {
        authorizationLabel
      }
    }
  }

  private var authorizationLabel: some View {
    HStack(spacing: 6) {
      Text("Authorization")
      if isDetecting { ProgressView().controlSize(.small) }
    }
  }

  private var cancelButton: some View {
    Button("Cancel", role: .cancel) { dismiss() }
      .settingsActionTint(theme)
      .keyboardShortcut(.cancelAction)
  }

  private var automaticAuthorizationLabel: String {
    guard let detectedAuthType else { return "Automatic" }
    switch detectedAuthType {
    case "oauth": return "Automatic (OAuth)"
    case "bearer": return "Automatic (Bearer Token)"
    default: return "Automatic (None)"
    }
  }

  private var isValid: Bool {
    let hasValidLocation: Bool
    if transport == "stdio" {
      hasValidLocation = ((try? CommandLineCodec.parse(location))?.isEmpty == false)
    } else {
      hasValidLocation = !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasValidLocation
      && validSecretEntries(headerEntries) && validSecretEntries(environmentEntries)
  }

  private func validSecretEntries(_ entries: [McpSecretEntry]) -> Bool {
    let names = entries.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard names.allSatisfy({ !$0.isEmpty }), Set(names).count == names.count else { return false }
    return entries.allSatisfy { $0.existing || !$0.value.isEmpty }
  }

  private func changedValues(_ entries: [McpSecretEntry]) -> [String: String] {
    Dictionary(
      uniqueKeysWithValues: entries.compactMap { entry in
        let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || entry.value.isEmpty ? nil : (name, entry.value)
      })
  }

  private func detectAuthorization() async {
    detectedAuthType = nil
    let scheme = URL(string: location)?.scheme?.lowercased()
    guard transport == "http", scheme == "http" || scheme == "https" else {
      return
    }
    do {
      try await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      isDetecting = true
      defer { isDetecting = false }
      let detection = try await client.detectMcpAuth(url: location)
      guard !Task.isCancelled else { return }
      detectedAuthType = detection.authType
      if !nameWasEdited, let suggestedName = detection.suggestedName {
        name = suggestedName
      }
    } catch is CancellationError {
      isDetecting = false
    } catch {
      isDetecting = false
    }
  }

  private func submit() async {
    isSaving = true
    defer { isSaving = false }
    do {
      let commandComponents = transport == "stdio" ? try CommandLineCodec.parse(location) : []
      try await save(
        McpFormValues(
          name: name,
          transport: transport,
          location: transport == "stdio" ? commandComponents[0] : location,
          arguments: transport == "stdio" ? Array(commandComponents.dropFirst()) : [],
          authSelection: authSelection,
          effectiveAuthType: effectiveAuthType,
          bearerToken: bearerToken.isEmpty ? nil : bearerToken,
          oauthScope: oauthScope.isEmpty ? nil : oauthScope,
          oauthClientId: clientId.isEmpty ? nil : clientId,
          oauthClientSecret: clientSecret.isEmpty ? nil : clientSecret,
          headers: changedValues(headerEntries),
          environment: changedValues(environmentEntries),
          removedHeaders: Array(initialHeaderNames.subtracting(headerEntries.map(\.name))),
          removedEnvironment: Array(initialEnvironmentNames.subtracting(environmentEntries.map(\.name)))
        ))
      dismiss()
    } catch let error as CommandLineCodec.ParseError {
      errorMessage = error.localizedDescription
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
  }
}
