import CodevisorCore
import CodevisorUI
import SwiftUI

struct OpenCodeProviderSetupRequest: Identifiable {
  let id = UUID()
  let providerId: String?
}

struct OpenCodeProviderSetupSheet: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  @Environment(\.sharedHarnessAccounts) private var isShared
  @Environment(\.harnessMachineSignIn) private var machineSignIn
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL

  let serverId: String
  let accountId: String
  let providers: [ServerOpenCodeAuthProvider]
  let initialProviderId: String?
  let onComplete: () -> Void

  @State private var selectedProviderId: String
  @State private var selectedMethodId = ""
  @State private var inputs: [String: String] = [:]
  @State private var apiKey = ""
  @State private var authorizationCode = ""
  @State private var flow: ServerOpenCodeAuthFlow?
  @State private var pollingFlowId: String?
  @State private var openedURL: String?
  /// Labeled rather than a bare flag so the status bar can name the work,
  /// matching `OpenCodeProviderAuthenticationView+Actions` on macOS.
  @State private var workingLabel: String?
  @State private var errorMessage: String?

  init(
    serverId: String,
    accountId: String,
    providers: [ServerOpenCodeAuthProvider],
    initialProviderId: String?,
    onComplete: @escaping () -> Void
  ) {
    self.serverId = serverId
    self.accountId = accountId
    self.providers = providers
    self.initialProviderId = initialProviderId
    self.onComplete = onComplete
    let choice =
      initialProviderId
      ?? providers.first(where: { $0.credentialType == nil })?.id
      ?? providers.first?.id
      ?? ""
    _selectedProviderId = State(initialValue: choice)
  }

  private var client: HarnessAccountsStore {
    HarnessAccountsStore(environment: environment, machineId: serverId, isShared: isShared)
  }

  private var selectedProvider: ServerOpenCodeAuthProvider? {
    providers.first { $0.id == selectedProviderId }
  }

  private var selectedMethod: ServerOpenCodeAuthMethod? {
    selectedProvider?.methods.first { $0.id == selectedMethodId }
  }

  var body: some View {
    NavigationStack {
      Form {
        if let errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
              .foregroundStyle(theme.statusError)
          }
        }

        if let flow {
          Section(selectedProvider?.name ?? "Authentication") {
            flowContent(flow)
          }
        } else {
          Section("Provider") {
            NavigationLink {
              HarnessProviderPicker(
                providers: providers.map { .init(id: $0.id, name: $0.name) },
                selection: $selectedProviderId)
            } label: {
              LabeledContent("Provider", value: selectedProvider?.name ?? "Choose…")
            }
            .onChange(of: selectedProviderId) { _, _ in selectDefaultMethod() }
          }

          if let provider = selectedProvider {
            Section("Authentication") {
              if provider.methods.count > 1 {
                Picker("Method", selection: $selectedMethodId) {
                  ForEach(provider.methods) { method in
                    Text(method.label).tag(method.id)
                  }
                }
                .onChange(of: selectedMethodId) { _, _ in resetInputs() }
              }

              if let method = selectedMethod {
                ForEach(visiblePrompts(method)) { prompt in
                  promptControl(prompt)
                }
                if method.type == "api" {
                  SecureField("API Key", text: $apiKey)
                    .textContentType(.password)
                    .privacySensitive()
                }

              }
            }
          }
        }
      }
      .navigationTitle(initialProviderId == nil ? "Add Provider" : "Replace Credential")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }.labelStyle(.iconOnly)
        }
        // Text labels: a bare `checkmark` for "Save" and a bare
        // `arrow.right` for "Sign In" are not tellable apart, let alone
        // guessable. `role: .confirm` already makes them prominent.
        if let flow {
          if flow.state == "waiting" {
            SheetConfirmToolbarItem(
              "Continue",
              isEnabled: !authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !isWorking
            ) {
              submitCode(flow)
            }
          }
        } else if let method = selectedMethod {
          SheetConfirmToolbarItem(
            method.type == "api" ? "Save" : "Sign In",
            isEnabled: canSubmit(method) && !isWorking
          ) {
            Task { await beginLogin() }
          }
        }
      }
    }
    .sheetStatus(statusLabel)
    // Deliberately no `.presentationDetents`. Measured on the simulator, a
    // detent-sized sheet presented over `HarnessSignInInvitation` samples
    // the invitation's prominent Sign In button into its own backdrop: a
    // blue wash and a blurred ghost of the button's label land across this
    // sheet's first rows. Presenting full height covers the invitation, so
    // there is nothing behind to sample.
    //
    // This is a presentation-backdrop quirk, not something this sheet
    // causes — `HarnessLoginStepScreen` keeps its detents and shows the
    // same artifact when it too is opened from the invitation, but is
    // clean when opened from the sign-in method list. Removing detents
    // here is a mitigation for the sheet that always has the invitation
    // behind it, not a fix for the underlying compositing.
    .interactiveDismissDisabled(isWorking)
    .task { selectDefaultMethod() }
    .onDisappear { cancelPendingFlow() }
  }

  private func visiblePrompts(_ method: ServerOpenCodeAuthMethod) -> [ServerOpenCodeAuthPrompt] {
    method.prompts.filter { prompt in
      guard let condition = prompt.when else { return true }
      guard let actual = inputs[condition.key] else { return false }
      return condition.op == "eq" ? actual == condition.value : actual != condition.value
    }
  }

  @ViewBuilder
  private func promptControl(_ prompt: ServerOpenCodeAuthPrompt) -> some View {
    if prompt.type == "select" {
      Picker(prompt.message, selection: inputBinding(prompt.key)) {
        ForEach(prompt.options) { option in
          Text(option.hint.map { "\(option.label) — \($0)" } ?? option.label)
            .tag(option.value)
        }
      }
    } else {
      TextField(prompt.placeholder ?? prompt.message, text: inputBinding(prompt.key))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }
  }

  private var isWorking: Bool { workingLabel != nil }

  /// Blocking work and the browser wait both report here, never in the
  /// body — the same rule macOS states on `HarnessLoginStepSheet`.
  private var statusLabel: String? {
    if let workingLabel { return workingLabel }
    return flow?.state == "running" ? "Waiting for sign-in…" : nil
  }

  @ViewBuilder
  private func flowContent(_ flow: ServerOpenCodeAuthFlow) -> some View {
    if let authorization = flow.authorization {
      if !authorization.instructions.isEmpty {
        Text(authorization.instructions).foregroundStyle(theme.textSecondary)
      }
      Button("Open Sign-In Page") { open(authorization.url) }
    }
    if flow.state == "waiting" {
      TextField("Authorization Code", text: $authorizationCode)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }
  }

  private func inputBinding(_ key: String) -> Binding<String> {
    Binding(
      get: { inputs[key] ?? "" },
      set: { inputs[key] = $0 }
    )
  }

  private func canSubmit(_ method: ServerOpenCodeAuthMethod) -> Bool {
    if method.type == "api", apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return false
    }
    return visiblePrompts(method).allSatisfy { prompt in
      !(inputs[prompt.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  private func selectDefaultMethod() {
    selectedMethodId = selectedProvider?.methods.first?.id ?? ""
    resetInputs()
  }

  private func resetInputs() {
    inputs = [:]
    apiKey = ""
    if let method = selectedMethod {
      for prompt in method.prompts where prompt.type == "select" {
        inputs[prompt.key] = prompt.options.first?.value ?? ""
      }
    }
  }

  private func beginLogin() async {
    guard let provider = selectedProvider, let method = selectedMethod, canSubmit(method) else { return }
    await perform("Starting sign-in…") {
      let next = try await client.startOpenCodeAuth(
        accountId: accountId,
        providerId: provider.id,
        methodId: method.id,
        inputs: inputs.isEmpty ? nil : inputs,
        apiKey: method.type == "api" ? apiKey : nil
      )
      await apply(next)
    }
  }

  private func submitCode(_ flow: ServerOpenCodeAuthFlow) {
    let code = authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !code.isEmpty else { return }
    Task {
      await perform("Verifying…") {
        let next = try await client.answerOpenCodeAuthFlow(id: flow.id, code: code)
        authorizationCode = ""
        await apply(next)
      }
    }
  }

  private func apply(_ next: ServerOpenCodeAuthFlow) async {
    flow = next
    if let url = next.authorization?.url, openedURL != url {
      openedURL = url
      open(url)
    }
    if next.state == "complete" {
      flow = nil
      pollingFlowId = nil
      onComplete()
      dismiss()
    } else if next.state == "error" {
      errorMessage = next.error ?? "OpenCode authentication failed."
      flow = nil
      pollingFlowId = nil
    } else if next.state == "running" || next.state == "waiting" {
      beginPolling(next.id)
    }
  }

  private func beginPolling(_ id: String) {
    guard pollingFlowId != id else { return }
    pollingFlowId = id
    Task {
      while !Task.isCancelled, pollingFlowId == id {
        try? await Task.sleep(for: .seconds(1))
        guard let next = try? await client.openCodeAuthFlow(id: id) else { continue }
        let pending = next.state == "running" || next.state == "waiting"
        if !pending { pollingFlowId = nil }
        await apply(next)
        if !pending { return }
      }
    }
  }

  private func cancelPendingFlow() {
    guard let flow, flow.state == "running" || flow.state == "waiting" else { return }
    self.flow = nil
    pollingFlowId = nil
    Task { try? await client.cancelOpenCodeAuthFlow(id: flow.id) }
  }

  private func perform(_ label: String, _ operation: () async throws -> Void) async {
    workingLabel = label
    errorMessage = nil
    defer { workingLabel = nil }
    do {
      try await operation()
    } catch {
      errorMessage = serverErrorMessage(error)
    }
  }

  private func open(_ value: String) {
    guard let url = URL(string: value) else { return }
    openURL(url)
  }
}
