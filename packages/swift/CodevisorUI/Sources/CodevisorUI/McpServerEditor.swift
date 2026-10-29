import CodevisorCore
import SwiftUI

public struct McpServerEditor: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss

  private let machineId: String
  private let save: (McpFormValues) async throws -> Void

  @State private var name = ""
  @State private var transport = "http"
  @State private var location = ""
  @State private var authSelection = "auto"
  @State private var detectedAuthType: String?
  @State private var isDetecting = false
  @State private var bearerToken = ""
  @State private var oauthScope = ""
  @State private var clientId = ""
  @State private var clientSecret = ""
  @State private var headerEntries: [McpSecretEntry] = []
  @State private var environmentEntries: [McpSecretEntry] = []
  @State private var showsAdvanced = false
  @State private var nameWasEdited = false
  @State private var isSaving = false
  @State private var errorMessage: String?
  @State private var detectTask: Task<Void, Never>?

  public init(machineId: String, save: @escaping (McpFormValues) async throws -> Void) {
    self.machineId = machineId
    self.save = save
  }

  private var effectiveAuthType: String {
    authSelection == "auto" ? (detectedAuthType ?? "none") : authSelection
  }

  private var canSave: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !isSaving
  }

  public var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Name", text: $name)
            .onChange(of: name) { _, _ in nameWasEdited = true }
          Picker("Type", selection: $transport) {
            Text("Server URL").tag("http")
            Text("Command").tag("stdio")
          }
          .pickerStyle(.segmented)
        }

        Section {
          TextField(
            transport == "http" ? "https://example.com/mcp" : "npx -y some-mcp-server",
            text: $location
          )
          .autocorrectionDisabled()
          #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(transport == "http" ? .URL : .asciiCapable)
          #endif
          .onChange(of: location) { _, _ in scheduleDetection() }
          if isDetecting {
            HStack(spacing: 8) {
              ProgressView().controlSize(.small)
              Text("Checking authorization…").foregroundStyle(.secondary)
            }
          }
        } header: {
          Text(transport == "http" ? "Address" : "Command")
        }

        if transport == "http" {
          authorizationSection
        } else {
          Section("Environment Variables") {
            McpSecretRows(entries: $environmentEntries, valuePrompt: "Value")
          }
        }

        Section { PluginConsentNotice(name: name.isEmpty ? "this plugin" : name) }

        if let errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.secondary)
          }
        }
      }
      .navigationTitle("Add MCP")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }.disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          if isSaving {
            ProgressView()
          } else {
            Button("Add") { Task { await submit() } }
              .disabled(!canSave)
          }
        }
      }
    }
    .interactiveDismissDisabled(isSaving)
    .onDisappear { detectTask?.cancel() }
  }

  @ViewBuilder
  private var authorizationSection: some View {
    Section {
      Picker("Authorization", selection: $authSelection) {
        Text(automaticLabel).tag("auto")
        Text("None").tag("none")
        Text("Bearer Token").tag("bearer")
        Text("OAuth").tag("oauth")
      }
      if effectiveAuthType == "bearer" {
        SecureField("Token", text: $bearerToken)
          .autocorrectionDisabled()
          #if os(iOS)
            .textInputAutocapitalization(.never)
          #endif
      }
      if effectiveAuthType == "oauth" {
        DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
          TextField("Scope", text: $oauthScope)
            .autocorrectionDisabled()
          TextField("Client ID", text: $clientId)
            .autocorrectionDisabled()
          SecureField("Client Secret", text: $clientSecret)
          Text(
            "With your own client ID, register each machine's Codevisor callback as a redirect URI with the provider. On a Mac it's usually http://127.0.0.1:49361/v1/mcps/oauth/callback; that Mac's Plugins settings show the exact URL."
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Authorization")
    }

    Section("HTTP Headers") {
      McpSecretRows(entries: $headerEntries, valuePrompt: "Value")
    }
  }

  private var automaticLabel: String {
    guard let detectedAuthType else { return "Automatic" }
    switch detectedAuthType {
    case "oauth": return "Automatic (OAuth)"
    case "bearer": return "Automatic (Bearer Token)"
    default: return "Automatic (None)"
    }
  }

  private func scheduleDetection() {
    detectTask?.cancel()
    detectTask = Task { await detectAuthorization() }
  }

  private func detectAuthorization() async {
    detectedAuthType = nil
    let scheme = URL(string: location)?.scheme?.lowercased()
    guard transport == "http", scheme == "http" || scheme == "https" else { return }
    try? await Task.sleep(for: .milliseconds(500))
    guard !Task.isCancelled else { return }
    isDetecting = true
    defer { isDetecting = false }
    guard
      let detection = try? await environment.machines.client(for: machineId)
        .detectMcpAuth(url: location)
    else { return }
    guard !Task.isCancelled else { return }
    detectedAuthType = detection.authType
    if !nameWasEdited, let suggested = detection.suggestedName {
      name = suggested
    }
  }

  private func changedValues(_ entries: [McpSecretEntry]) -> [String: String] {
    Dictionary(
      uniqueKeysWithValues: entries.compactMap { entry in
        let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || entry.value.isEmpty ? nil : (name, entry.value)
      })
  }

  private func submit() async {
    isSaving = true
    defer { isSaving = false }
    do {
      let components = transport == "stdio" ? try CommandLineCodec.parse(location) : []
      if transport == "stdio" && components.isEmpty {
        errorMessage = "Enter a command to run."
        return
      }
      try await save(
        McpFormValues(
          name: name.trimmingCharacters(in: .whitespacesAndNewlines),
          transport: transport,
          location: transport == "stdio" ? components[0] : location,
          arguments: transport == "stdio" ? Array(components.dropFirst()) : [],
          authSelection: authSelection,
          effectiveAuthType: effectiveAuthType,
          bearerToken: bearerToken.isEmpty ? nil : bearerToken,
          oauthScope: oauthScope.isEmpty ? nil : oauthScope,
          oauthClientId: clientId.isEmpty ? nil : clientId,
          oauthClientSecret: clientSecret.isEmpty ? nil : clientSecret,
          headers: changedValues(headerEntries),
          environment: changedValues(environmentEntries)))
      dismiss()
    } catch let error as CommandLineCodec.ParseError {
      errorMessage = error.localizedDescription
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
  }
}
