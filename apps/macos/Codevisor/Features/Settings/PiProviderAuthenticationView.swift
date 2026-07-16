import AppKit
import CodevisorCore
import SwiftUI

struct PiProviderAuthenticationView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let harness: ServerHarness
    var onChange: (ServerHarness) -> Void

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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HarnessIcon(harnessId: "pi", fallbackSymbolName: harness.symbolName, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pi Providers").font(.title2).fontWeight(.semibold)
                    Text("Add and manage the model accounts Pi uses for new chats.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .settingsActionTint(theme)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            Form {
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Configured Providers") {
                    if configuredProviders.isEmpty {
                        Text("No providers configured yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(configuredProviders) { provider in
                            providerRow(provider)
                        }
                    }
                }

                if flow == nil {
                    Section("Add Provider") {
                        Picker("Provider", selection: $selectedProviderId) {
                            ForEach(providers) { provider in
                                Text(provider.name).tag(provider.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: selectedProviderId) { _, _ in selectDefaultMethod() }

                        if let provider = selectedProvider, provider.methods.count > 1 {
                            Picker("Authentication", selection: $selectedMethod) {
                                ForEach(provider.methods, id: \.self) { method in
                                    Text(methodLabel(method)).tag(method)
                                }
                            }
                            .pickerStyle(.segmented)
                        } else if let method = selectedProvider?.methods.first {
                            LabeledContent("Authentication", value: methodLabel(method))
                        }

                        HStack {
                            Spacer()
                            Button(actionLabel) { Task { await beginLogin() } }
                                .settingsActionTint(theme)
                                .disabled(selectedProvider == nil || isWorking)
                        }
                    }
                }

                if let flow {
                    Section(flowTitle(flow)) {
                        flowContent(flow)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 540, idealWidth: 540, maxWidth: 540, minHeight: 430)
        .task { await load() }
        .onDisappear {
            guard let flow, flow.state != "complete", flow.state != "error" else { return }
            Task { try? await environment.serverClient.cancelPiAuthFlow(id: flow.id) }
        }
    }

    private var configuredProviders: [ServerPiAuthProvider] {
        providers.filter { $0.credentialType != nil }
    }

    private var selectedProvider: ServerPiAuthProvider? {
        providers.first { $0.id == selectedProviderId }
    }

    private var actionLabel: String {
        selectedMethod == "oauth" ? "Sign In" : "Add API Key"
    }

    @ViewBuilder
    private func providerRow(_ provider: ServerPiAuthProvider) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(theme.textPrimary)
                .accessibilityLabel("Configured")
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                Text(provider.credentialType == "oauth" ? "Signed in with an account" : "API key configured")
                    .font(.callout)
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
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .settingsActionTint(theme)
            .accessibilityLabel("More actions for \(provider.name)")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func flowContent(_ flow: ServerPiAuthFlow) -> some View {
        if let event = flow.event {
            eventContent(event)
        }

        if let prompt = flow.prompt, flow.state == "waiting" {
            VStack(alignment: .leading, spacing: 10) {
                Text(prompt.message)
                if prompt.type == "select" {
                    Picker("", selection: $selectedOption) {
                        ForEach(prompt.options) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                } else if prompt.type == "secret" {
                    SecureField(prompt.placeholder ?? "Credential", text: $response)
                        .textContentType(.password)
                        .onSubmit { submitPrompt(flow, prompt: prompt) }
                } else {
                    TextField(prompt.placeholder ?? "Response", text: $response)
                        .onSubmit { submitPrompt(flow, prompt: prompt) }
                }
                HStack {
                    Button("Cancel") { Task { await cancel(flow) } }
                        .settingsActionTint(theme)
                    Spacer()
                    Button("Continue") { submitPrompt(flow, prompt: prompt) }
                        .settingsActionTint(theme)
                        .keyboardShortcut(.defaultAction)
                        .disabled(promptResponse(prompt).isEmpty || isWorking)
                }
            }
        } else if flow.state == "running" {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(flow.event?.message ?? "Waiting for authentication…")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { Task { await cancel(flow) } }
                    .settingsActionTint(theme)
            }
        }
    }

    @ViewBuilder
    private func eventContent(_ event: ServerPiAuthEvent) -> some View {
        switch event.type {
        case "device_code":
            Text("Enter this code in your browser:")
            Text(event.userCode ?? "")
                .font(.system(.title2, design: .monospaced, weight: .semibold))
                .textSelection(.enabled)
            HStack {
                Button("Copy Code") { copy(event.userCode ?? "") }
                    .settingsActionTint(theme)
                if let url = event.verificationUrl {
                    Button("Open Browser") { open(url) }
                        .settingsActionTint(theme)
                }
            }
        case "auth_url":
            if let message = event.message { Text(message).foregroundStyle(.secondary) }
            if let url = event.url {
                Button("Open Sign-In Page") { open(url) }
                    .settingsActionTint(theme)
            }
        case "info":
            if let message = event.message { Text(message).foregroundStyle(.secondary) }
            if let url = event.url {
                Button("Open Help") { open(url) }
                    .settingsActionTint(theme)
            }
        default:
            EmptyView()
        }
    }

    private func flowTitle(_ flow: ServerPiAuthFlow) -> String {
        providers.first { $0.id == flow.providerId }?.name ?? "Authentication"
    }

    private func methodLabel(_ method: String) -> String {
        method == "oauth" ? "Provider account" : "API key"
    }

    private func selectDefaultMethod() {
        guard let provider = selectedProvider else { return }
        selectedMethod = provider.methods.first ?? "api_key"
    }

    private func load() async {
        await perform {
            providers = try await environment.serverClient.listPiAuthProviders()
            if !providers.contains(where: { $0.id == selectedProviderId }) {
                selectedProviderId = providers.first(where: { $0.credentialType == nil })?.id
                    ?? providers.first?.id
                    ?? ""
            }
            selectDefaultMethod()
        }
    }

    private func beginLogin() async {
        guard let provider = selectedProvider else { return }
        await perform {
            let next = try await environment.serverClient.startPiAuth(
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
                let next = try await environment.serverClient.answerPiAuthFlow(id: flow.id, value: value)
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
                guard let next = try? await environment.serverClient.piAuthFlow(id: id) else { continue }
                let isPending = next.state == "running" || next.state == "waiting"
                if !isPending { pollingFlowId = nil }
                await apply(next)
                if !isPending { return }
            }
        }
    }

    private func cancel(_ flow: ServerPiAuthFlow) async {
        try? await environment.serverClient.cancelPiAuthFlow(id: flow.id)
        self.flow = nil
        pollingFlowId = nil
        response = ""
        selectedOption = ""
    }

    private func remove(_ provider: ServerPiAuthProvider) async {
        await perform {
            try await environment.serverClient.removePiAuthProvider(id: provider.id)
            await load()
            await refreshHarness()
        }
    }

    private func refreshHarness() async {
        if let updated = try? await environment.refreshHarnessAuthentication(harnessId: harness.id) {
            onChange(updated)
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await operation()
            errorMessage = nil
        } catch {
            errorMessage = serverErrorMessage(error)
        }
    }

    private func open(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
