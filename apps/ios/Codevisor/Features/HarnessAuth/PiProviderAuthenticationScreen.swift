import CodevisorCore
import SwiftUI
import UIKit

/// Pi authenticates model providers, not the Pi harness itself. This mobile
/// form exposes that provider flow directly instead of sending an unsupported
/// generic harness-login request.
struct PiProviderAuthenticationScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.openURL) private var openURL

  let serverId: String
  let harness: ServerHarness
  var onAuthenticated: () -> Void = {}

  @State private var providers: [ServerPiAuthProvider] = []
  @State private var selectedProviderId = ""
  @State private var selectedMethod = "api_key"
  @State private var flow: ServerPiAuthFlow?
  @State private var response = ""
  @State private var selectedOption = ""
  @State private var isWorking = false
  @State private var errorMessage: String?
  @State private var openedURL: String?
  @State private var pollingFlowId: String?

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: serverId)
  }

  private var configuredProviders: [ServerPiAuthProvider] {
    providers.filter { $0.credentialType != nil }
  }

  private var selectedProvider: ServerPiAuthProvider? {
    providers.first { $0.id == selectedProviderId }
  }

  var body: some View {
    Form {
      if let errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
        }
      }

      Section("Configured Providers") {
        if configuredProviders.isEmpty {
          Text("No providers configured.")
            .foregroundStyle(.secondary)
        }
        ForEach(configuredProviders) { provider in
          providerRow(provider)
        }
      }

      if flow == nil {
        Section("Add Provider") {
          Picker("Provider", selection: $selectedProviderId) {
            ForEach(providers) { provider in
              Text(provider.name).tag(provider.id)
            }
          }
          .onChange(of: selectedProviderId) { _, _ in selectDefaultMethod() }

          if let provider = selectedProvider, provider.methods.count > 1 {
            Picker("Sign in with", selection: $selectedMethod) {
              ForEach(provider.methods, id: \.self) { method in
                Text(methodLabel(method)).tag(method)
              }
            }
          } else if let method = selectedProvider?.methods.first {
            LabeledContent("Sign in with", value: methodLabel(method))
          }

          Button(selectedMethod == "oauth" ? "Sign In" : "Add API Key") {
            Task { await beginLogin() }
          }
          .disabled(selectedProvider == nil || isWorking)
        }
      }

      if let flow {
        Section(flowTitle(flow)) {
          flowContent(flow)
        }
      }
    }
    .task { await load() }
    .onDisappear { cancelPendingFlow() }
  }

  private func providerRow(_ provider: ServerPiAuthProvider) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .accessibilityLabel("Configured")
      VStack(alignment: .leading, spacing: 2) {
        Text(provider.name)
        Text(provider.credentialType == "oauth" ? "Provider account" : "API key")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Menu {
        Button("Replace Credential") {
          selectedProviderId = provider.id
          selectDefaultMethod()
        }
        Button("Remove Credential", role: .destructive) {
          Task { await remove(provider) }
        }
      } label: {
        Image(systemName: "ellipsis")
          .frame(width: 32, height: 32)
      }
    }
  }

  @ViewBuilder
  private func flowContent(_ flow: ServerPiAuthFlow) -> some View {
    if let event = flow.event {
      eventContent(event)
    }

    if let prompt = flow.prompt, flow.state == "waiting" {
      Text(prompt.message)
      if prompt.type == "select" {
        Picker("Response", selection: $selectedOption) {
          ForEach(prompt.options) { option in
            Text(option.label).tag(option.id)
          }
        }
      } else if prompt.type == "secret" {
        SecureField(prompt.placeholder ?? "Credential", text: $response)
          .textContentType(.password)
      } else {
        TextField(prompt.placeholder ?? "Response", text: $response)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
      }
      Button("Continue") { submitPrompt(flow, prompt: prompt) }
        .disabled(promptResponse(prompt).isEmpty || isWorking)
      Button("Cancel", role: .cancel) { Task { await cancel(flow) } }
    } else if flow.state == "running" {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text(flow.event?.message ?? "Waiting for sign-in…")
          .foregroundStyle(.secondary)
      }
      Button("Cancel", role: .cancel) { Task { await cancel(flow) } }
    }
  }

  @ViewBuilder
  private func eventContent(_ event: ServerPiAuthEvent) -> some View {
    if event.type == "device_code" {
      Text("Enter this code in your browser:")
      Text(event.userCode ?? "")
        .font(.system(.title2, design: .monospaced, weight: .semibold))
      Button("Copy Code") { UIPasteboard.general.string = event.userCode }
      if let url = event.verificationUrl {
        Button("Open Browser") { open(url) }
      }
    } else {
      if let message = event.message {
        Text(message).foregroundStyle(.secondary)
      }
      if let url = event.url ?? event.verificationUrl {
        Button(event.type == "auth_url" ? "Open Sign-In Page" : "Open Link") {
          open(url)
        }
      }
    }
  }

  private func flowTitle(_ flow: ServerPiAuthFlow) -> String {
    providers.first { $0.id == flow.providerId }?.name ?? "Authentication"
  }

  private func methodLabel(_ method: String) -> String {
    method == "oauth" ? "Provider account" : "API key"
  }

  private func selectDefaultMethod() {
    selectedMethod = selectedProvider?.methods.first ?? "api_key"
  }

  private func load() async {
    await perform {
      providers = try await client.listPiAuthProviders()
      if !providers.contains(where: { $0.id == selectedProviderId }) {
        selectedProviderId =
          providers.first(where: { $0.credentialType == nil })?.id
          ?? providers.first?.id
          ?? ""
      }
      selectDefaultMethod()
    }
  }

  private func beginLogin() async {
    guard let provider = selectedProvider else { return }
    await perform {
      let next = try await client.startPiAuth(
        providerId: provider.id,
        method: selectedMethod
      )
      await apply(next)
    }
  }

  private func submitPrompt(_ flow: ServerPiAuthFlow, prompt: ServerPiAuthPrompt) {
    let value = promptResponse(prompt)
    guard !value.isEmpty else { return }
    Task {
      await perform {
        let next = try await client.answerPiAuthFlow(id: flow.id, value: value)
        response = ""
        selectedOption = ""
        await apply(next)
      }
    }
  }

  private func promptResponse(_ prompt: ServerPiAuthPrompt) -> String {
    (prompt.type == "select" ? selectedOption : response)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func apply(_ next: ServerPiAuthFlow) async {
    flow = next
    if let prompt = next.prompt, prompt.type == "select", selectedOption.isEmpty {
      selectedOption = prompt.options.first?.id ?? ""
    }
    if let url = next.event?.url ?? next.event?.verificationUrl, openedURL != url {
      openedURL = url
      open(url)
    }
    if next.state == "complete" {
      flow = nil
      pollingFlowId = nil
      await load()
      await refreshHarness()
    } else if next.state == "error" {
      errorMessage = next.error ?? "Pi authentication failed."
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
        guard let next = try? await client.piAuthFlow(id: id) else { continue }
        let pending = next.state == "running" || next.state == "waiting"
        if !pending { pollingFlowId = nil }
        await apply(next)
        if !pending { return }
      }
    }
  }

  private func cancel(_ flow: ServerPiAuthFlow) async {
    try? await client.cancelPiAuthFlow(id: flow.id)
    self.flow = nil
    pollingFlowId = nil
    response = ""
    selectedOption = ""
  }

  private func cancelPendingFlow() {
    guard let flow, flow.state == "running" || flow.state == "waiting" else { return }
    self.flow = nil
    pollingFlowId = nil
    Task { try? await client.cancelPiAuthFlow(id: flow.id) }
  }

  private func remove(_ provider: ServerPiAuthProvider) async {
    await perform {
      try await client.removePiAuthProvider(id: provider.id)
      await load()
      await refreshHarness()
    }
  }

  private func refreshHarness() async {
    guard
      let updated = try? await environment.refreshHarnessAuthentication(
        harnessId: harness.id,
        onServer: serverId
      )
    else { return }
    let wasUsable = harness.auth?.state == "authenticated" || harness.auth?.state == "notRequired"
    if !wasUsable,
      updated.auth?.state == "authenticated" || updated.auth?.state == "notRequired"
    {
      onAuthenticated()
    }
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
