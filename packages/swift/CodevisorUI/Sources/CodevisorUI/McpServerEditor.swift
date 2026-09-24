import CodevisorCore
import SwiftUI

/// Adding or editing an MCP server, in plain SwiftUI so both apps can use
/// it. The Mac's own sheet exists only because its controls are AppKit
/// workarounds for theming a segmented bezel and scrolling a long value —
/// nothing about defining a server is desktop-specific, and the create call
/// has always been in the shared client.
public struct McpServerEditor: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.dismiss) private var dismiss

  private let initialServer: ServerMcpServer?
  private let machineId: String
  private let save: (McpFormValues) async throws -> Void

  @State private var name: String
  @State private var transport: String
  @State private var location: String
  @State private var authSelection: String
  @State private var detectedAuthType: String?
  @State private var isDetecting = false
  @State private var bearerToken = ""
  @State private var oauthScope: String
  @State private var clientId = ""
  @State private var clientSecret = ""
  @State private var headerEntries: [McpSecretEntry]
  @State private var environmentEntries: [McpSecretEntry]
  @State private var showsAdvanced = false
  @State private var nameWasEdited: Bool
  @State private var isSaving = false
  @State private var errorMessage: String?
  @State private var detectTask: Task<Void, Never>?

  private let initialHeaderNames: Set<String>
  private let initialEnvironmentNames: Set<String>

  public init(
    initialServer: ServerMcpServer?,
    machineId: String,
    save: @escaping (McpFormValues) async throws -> Void
  ) {
    self.initialServer = initialServer
    self.machineId = machineId
    self.save = save
    _name = State(initialValue: initialServer?.name ?? "")
    _transport = State(initialValue: initialServer?.transport ?? "http")
    _location = State(
      initialValue: initialServer?.url
        ?? CommandLineCodec.format(
          [initialServer?.command].compactMap { $0 } + (initialServer?.args ?? [])))
    _authSelection = State(initialValue: initialServer?.authType ?? "auto")
    _detectedAuthType = State(initialValue: initialServer?.authType)
    _oauthScope = State(initialValue: initialServer?.oauthScope ?? "")
    _nameWasEdited = State(initialValue: initialServer != nil)
    let headerNames = Set(initialServer?.headerNames ?? [])
    let environmentNames = Set(initialServer?.environmentNames ?? [])
    initialHeaderNames = headerNames
    initialEnvironmentNames = environmentNames
    _headerEntries = State(
      initialValue: headerNames.sorted().map { McpSecretEntry(name: $0, value: "", existing: true) })
    _environmentEntries = State(
      initialValue: environmentNames.sorted().map {
        McpSecretEntry(name: $0, value: "", existing: true)
      })
  }

  private var isEditing: Bool { initialServer != nil }

  /// "Automatic" means whatever the probe found; the server decides when
  /// nothing was detected.
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
          // Transport decides what the record even is; changing it after
          // the fact would invalidate the saved address.
          .disabled(isEditing)
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

        if let errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.secondary)
          }
        }
      }
      .navigationTitle(isEditing ? "Edit MCP Server" : "Add MCP Server")
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
            Button(isEditing ? "Save" : "Add") { Task { await submit() } }
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

  /// Probing costs a request, so it waits for a pause in typing. Editing an
  /// existing server keeps whatever it was created with unless the address
  /// actually changes.
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

  /// Only entries the user actually typed a value into are sent; an
  /// untouched existing row keeps whatever the server already has.
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
          environment: changedValues(environmentEntries),
          removedHeaders: Array(initialHeaderNames.subtracting(headerEntries.map(\.name))),
          removedEnvironment: Array(
            initialEnvironmentNames.subtracting(environmentEntries.map(\.name)))))
      dismiss()
    } catch let error as CommandLineCodec.ParseError {
      errorMessage = error.localizedDescription
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
    }
  }
}
