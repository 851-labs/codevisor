import AppKit
import CodevisorCore
import SwiftUI
import CodevisorUI

// MARK: - Provider sign-in sheet

extension OpenCodeProviderAuthenticationView {
    var providerSignInSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text(flow == nil ? "Add Provider" : (selectedProvider?.name ?? "Sign In"))
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Button("Cancel") { showingProviderSignIn = false }
                    .settingsActionTint(theme)
            }
            .padding(20)

            Divider()

            if let flow {
                Form {
                    Section(selectedProvider?.name ?? "Authentication") {
                        flowContent(flow)
                    }
                }
                .formStyle(.grouped)
            } else {
                VStack(spacing: 12) {
                    TextField("Search Providers", text: $providerSearch)
                        .textFieldStyle(.roundedBorder)

                    List(filteredProviders, selection: $selectedProviderId) { provider in
                        HStack {
                            Text(provider.name)
                            Spacer()
                            if provider.credentialType != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Configured")
                            }
                        }
                        .tag(provider.id)
                    }
                    .onChange(of: selectedProviderId) { _, _ in selectDefaultMethod() }
                    .frame(minHeight: 170)

                    Divider()

                    if let provider = selectedProvider {
                        authenticationControls(provider)
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 480, idealWidth: 500, minHeight: 430, idealHeight: 480)
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
                HStack {
                    Spacer()
                    Button(method.type == "api" ? "Save API Key" : "Sign In") {
                        Task { await beginLogin() }
                    }
                    .settingsActionTint(theme)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit(method) || isWorking)
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
                    .foregroundStyle(.secondary)
            }
            Button("Open Sign-In Page") { open(authorization.url) }
                .settingsActionTint(theme)
        }

        if flow.state == "waiting" {
            TextField("Authorization Code", text: $authorizationCode)
                .onSubmit { submitCode(flow) }
            HStack {
                Spacer()
                Button("Continue") { submitCode(flow) }
                    .settingsActionTint(theme)
                    .keyboardShortcut(.defaultAction)
                    .disabled(authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
            }
        } else if flow.state == "running" {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for sign-in…")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
