import AppKit
import CodevisorCore
import SwiftUI
import CodevisorUI

// MARK: - Provider sign-in sheet

extension OpenCodeProviderAuthenticationView {
  /// The browser wait is chrome status, not body content — same rule the
  /// rest of the family follows.
  var providerSignInStatus: String? {
    if flow?.state == "running" { return "Waiting for sign-in…" }
    return workingLabel
  }

  var providerSignInSheet: some View {
    NavigationStack {
      Group {
        if let flow {
          Form { Section { flowContent(flow) } }.formStyle(.grouped)
        } else {
          VStack(spacing: 0) {
            List(filteredProviders, selection: $selectedProviderId) { provider in
              HStack {
                Text(provider.name)
                Spacer()
                if provider.credentialType != nil {
                  Image(systemName: "checkmark").accessibilityLabel("Configured")
                }
              }.tag(provider.id)
            }
            .searchable(text: $providerSearch, placement: .toolbar, prompt: "Search providers")
            .onChange(of: selectedProviderId) { _, _ in selectDefaultMethod() }
            if let provider = selectedProvider {
              Divider()
              authenticationControls(provider).padding(20)
            }
          }
        }
      }
      .navigationTitle(flow == nil ? "Add Provider" : (selectedProvider?.name ?? "Sign In"))
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      SheetFooter(status: providerSignInStatus) {
        Button("Cancel", role: .cancel) { showingProviderSignIn = false }
          .settingsActionTint(theme)
          .keyboardShortcut(.cancelAction)
          .disabled(isWorking)
        if let flow {
          if flow.state == "waiting" {
            Button("Continue") { submitCode(flow) }
              .settingsActionTint(theme)
              .keyboardShortcut(.defaultAction)
              .disabled(authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
          }
        } else if let method = selectedMethod {
          Button(method.type == "api" ? "Save" : "Sign In") { Task { await beginLogin() } }
            .settingsActionTint(theme)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit(method) || isWorking)
        }
      }
    }
    .sheetSize(.list)
    .themedSurface(.sheet)
  }

  @ViewBuilder
  private func authenticationControls(_ provider: ServerOpenCodeAuthProvider) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      if provider.methods.count > 1 {
        Picker("Authentication", selection: $selectedMethodId) {
          ForEach(provider.methods) { method in
            Text(method.label).tag(method.id)
          }
        }
        .pickerStyle(.menu)
        .onChange(of: selectedMethodId) { _, _ in resetInput() }
      } else if let method = selectedMethod {
        LabeledContent("Authentication", value: method.label)
      }

      if let method = selectedMethod {
        ForEach(visiblePrompts(method)) { prompt in
          promptControl(prompt)
        }
        if method.type == "api" {
          SecureField("API Key", text: $apiKey)
            .textContentType(.password)
            .onSubmit { submitSelectedMethod() }
        }

      }
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
      .pickerStyle(.menu)
    } else {
      TextField(prompt.placeholder ?? prompt.message, text: inputBinding(prompt.key))
    }
  }

  @ViewBuilder
  private func flowContent(_ flow: ServerOpenCodeAuthFlow) -> some View {
    if let authorization = flow.authorization {
      if !authorization.instructions.isEmpty {
        Text(authorization.instructions)
          .foregroundStyle(theme.textSecondary)
      }
      Button("Open Sign-In Page") { open(authorization.url) }
        .settingsActionTint(theme)
    }

    if flow.state == "waiting" {
      TextField("Authorization Code", text: $authorizationCode)
        .onSubmit { submitCode(flow) }

    }
  }
}
