import CodevisorCore
import CodevisorUI
import SwiftUI

struct OpenCodeProviderSetupRequest: Identifiable {
  let id = UUID()
  let providerId: String?
}

struct OpenCodeProviderSetupSheet: View {
  @Environment(AppEnvironment.self) private var environment
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
  @State private var isWorking = false
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
              .foregroundStyle(.secondary)
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
        if let flow {
          if flow.state == "waiting" {
            ToolbarItem(placement: .confirmationAction) {
              Button(role: .confirm) {
                submitCode(flow)
              } label: {
                Label("Continue", systemImage: "checkmark")
              }.labelStyle(.iconOnly)
                .disabled(authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
            }
          }
        } else if let method = selectedMethod {
          ToolbarItem(placement: .confirmationAction) {
            Button(role: .confirm) {
              Task { await beginLogin() }
            } label: {
              Label(
                method.type == "api" ? "Save" : "Sign In",
                systemImage: method.type == "api" ? "checkmark" : "arrow.right")
            }.labelStyle(.iconOnly).disabled(!canSubmit(method) || isWorking)
          }
        }
      }
    }
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

  @ViewBuilder
  private func flowContent(_ flow: ServerOpenCodeAuthFlow) -> some View {
    if let authorization = flow.authorization {
      if !authorization.instructions.isEmpty {
        Text(authorization.instructions).foregroundStyle(.secondary)
      }
      Button("Open Sign-In Page") { open(authorization.url) }
    }
    if flow.state == "waiting" {
      TextField("Authorization Code", text: $authorizationCode)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    } else if flow.state == "running" {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Waiting for sign-in…").foregroundStyle(.secondary)
      }
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
    await perform {
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
      await perform {
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

  private func perform(_ operation: () async throws -> Void) async {
    isWorking = true
    errorMessage = nil
    defer { isWorking = false }
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
