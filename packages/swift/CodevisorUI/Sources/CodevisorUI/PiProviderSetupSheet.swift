import CodevisorCore
import SwiftUI
#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

struct PiProviderSetupSheet: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.sharedHarnessAccounts) private var isShared
  @Environment(\.harnessMachineSignIn) private var machineSignIn
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @Environment(\.theme) private var theme
  let machineId: String
  let providers: [ServerPiAuthProvider]
  let initialProviderId: String?
  let onComplete: () -> Void
  @State private var selectedProviderId = ""
  @State private var selectedMethod = "api_key"
  @State private var apiKey = ""
  @State private var flow: ServerPiAuthFlow?
  @State private var response = ""
  @State private var selectedOption = ""
  @State private var isWorking = false
  @State private var errorMessage: String?
  @State private var openedURL: String?
  @State private var pollingFlowId: String?

  private var client: HarnessAccountsStore {
    HarnessAccountsStore(environment: environment, machineId: machineId, isShared: isShared)
  }
  private var provider: ServerPiAuthProvider? { providers.first { $0.id == selectedProviderId } }
  private var actionTitle: String { flow != nil ? "Continue" : (selectedMethod == "api_key" ? "Save" : "Sign In") }
  /// What the sheet's chrome says while a submit is in flight. Never a
  /// button title swap — that would resize the button mid-operation.
  private var workingLabel: String? {
    if flow?.state == "running" { return "Waiting for sign-in…" }
    guard isWorking else { return nil }
    return selectedMethod == "api_key" && flow == nil ? "Saving…" : "Signing in…"
  }
  private var canSubmit: Bool {
    guard !isWorking else { return false }
    if let flow { return flow.state == "waiting" && flow.prompt.map { !promptResponse($0).isEmpty } == true }
    return provider != nil
      && (selectedMethod != "api_key" || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  var body: some View {
    NavigationStack {
      Form {
        if let errorMessage {
          Section { Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(theme.statusError) }
        }
        if let flow {
          Section { flowContent(flow) }
        } else {
          Section {
            NavigationLink {
              HarnessProviderPicker(
                providers: providers.map { .init(id: $0.id, name: $0.name) }, selection: $selectedProviderId)
            } label: {
              LabeledContent("Provider", value: provider?.name ?? "Choose…")
            }
            if let provider, provider.methods.count > 1 {
              Picker("Sign in with", selection: $selectedMethod) {
                ForEach(provider.methods, id: \.self) { method in
                  Text(method == "oauth" ? "Provider account" : "API key").tag(method)
                }
              }
            }
            if selectedMethod == "api_key" {
              SecureField("API Key", text: $apiKey).privacySensitive()
                .onSubmit { submit() }
            }
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle(initialProviderId == nil ? "Add Provider" : (provider?.name ?? "Provider"))
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
            .labelStyle(.iconOnly).disabled(isWorking)
          }
          if flow?.state != "running" {
            // Text: the verb is the whole point. `role: .confirm` already
            // renders it prominent on iOS 26.
            SheetConfirmToolbarItem(actionTitle, isEnabled: canSubmit && !isWorking) {
              submit()
            }
          }
        }
      #endif
    }
    #if os(macOS)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        SheetFooter(status: workingLabel) {
          Button("Cancel", role: .cancel) { dismiss() }
          .settingsActionTint(theme)
          .keyboardShortcut(.cancelAction)
          .disabled(isWorking)
          if flow?.state != "running" {
            Button(actionTitle) { submit() }
            .settingsActionTint(theme)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit)
          }
        }
      }
      .sheetSize(.step)
      .themedSurface(.sheet)
    #endif
    #if os(iOS)
      .sheetStatus(workingLabel)
      .presentationDetents([.medium, .large])
    #endif
    .interactiveDismissDisabled(isWorking)
    .onAppear {
      guard selectedProviderId.isEmpty else { return }
      selectedProviderId =
        initialProviderId ?? providers.first(where: { $0.credentialType == nil })?.id ?? providers.first?.id ?? ""
      selectedMethod = provider?.methods.first ?? "api_key"
    }
    .onChange(of: selectedProviderId) { _, _ in
      selectedMethod = provider?.methods.first ?? "api_key"; apiKey = ""
    }
    .task(id: pollingFlowId) {
      guard let id = pollingFlowId else { return }
      while !Task.isCancelled, pollingFlowId == id {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        guard !Task.isCancelled, let next = try? await client.piAuthFlow(id: id) else { continue }
        apply(next)
      }
    }
    .onDisappear {
      pollingFlowId = nil
      if let flow, flow.state == "running" || flow.state == "waiting" {
        Task { try? await client.cancelPiAuthFlow(id: flow.id) }
      }
    }
  }

  @ViewBuilder private func flowContent(_ flow: ServerPiAuthFlow) -> some View {
    if let event = flow.event {
      if let code = event.userCode {
        LabeledContent("Code") {
          HStack {
            Text(code).font(.headline.monospaced()).textSelection(.enabled)
            Button("Copy Code", systemImage: "doc.on.doc") { copy(code) }.labelStyle(.iconOnly).buttonStyle(.borderless)
          }
        }
      }
      if let message = event.message { Text(message).foregroundStyle(theme.textSecondary) }
      if let value = event.url ?? event.verificationUrl, let url = URL(string: value) {
        Link("Open Sign-In Page", destination: url)
      }
    }
    if let prompt = flow.prompt, flow.state == "waiting" {
      if prompt.type == "select" {
        Picker(prompt.message, selection: $selectedOption) {
          ForEach(prompt.options) { option in Text(option.label).tag(option.id) }
        }
      } else if prompt.type == "secret" || selectedMethod == "api_key" {
        SecureField(prompt.placeholder ?? prompt.message, text: $response).privacySensitive().onSubmit { submit() }
      } else {
        TextField(prompt.placeholder ?? prompt.message, text: $response).onSubmit { submit() }
          #if os(iOS)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
          #endif
      }
    }
  }

  private func submit() {
    guard canSubmit else { return }
    isWorking = true
    Task {
      defer { isWorking = false }
      do {
        let next: ServerPiAuthFlow
        if let flow, let prompt = flow.prompt {
          next = try await client.answerPiAuthFlow(id: flow.id, value: promptResponse(prompt))
          response = ""
        } else {
          let started = try await client.startPiAuth(providerId: selectedProviderId, method: selectedMethod)
          flow = started
          if selectedMethod == "api_key", started.state == "waiting", started.prompt != nil {
            next = try await client.answerPiAuthFlow(
              id: started.id, value: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
          } else {
            next = started
          }
        }
        errorMessage = nil
        apply(next)
      } catch { errorMessage = serverErrorMessage(error) }
    }
  }
  private func promptResponse(_ prompt: ServerPiAuthPrompt) -> String {
    (prompt.type == "select" ? selectedOption : response).trimmingCharacters(in: .whitespacesAndNewlines)
  }
  private func apply(_ next: ServerPiAuthFlow) {
    flow = next
    if next.prompt?.type == "select", selectedOption.isEmpty { selectedOption = next.prompt?.options.first?.id ?? "" }
    if let value = next.event?.url ?? next.event?.verificationUrl, value != openedURL, let url = URL(string: value) {
      openedURL = value; openURL(url)
    }
    if next.state == "complete" {
      flow = nil; pollingFlowId = nil; onComplete(); dismiss()
    } else if next.state == "error" {
      errorMessage = next.error ?? "Sign-in failed."; flow = nil; pollingFlowId = nil
    } else if next.state == "running" || next.state == "waiting" {
      pollingFlowId = next.id
    }
  }
  private func copy(_ value: String) {
    #if os(macOS)
      NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
    #else
      UIPasteboard.general.string = value
    #endif
  }
}
