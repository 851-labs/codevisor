import CodevisorCore
import SwiftUI
import UIKit

/// One sign-in attempt presented as a compact, platform-standard form.
enum HarnessLoginStep: Identifiable {
    case flow(ServerHarnessAuthFlow)
    case apiKey(account: ServerHarnessAccount, method: ServerHarnessAuthMethod)

    var id: String {
        switch self {
        case .flow(let flow): "flow-\(flow.id)"
        case .apiKey(let account, _): "apiKey-\(account.id)"
        }
    }
}

struct HarnessLoginStepScreen: View {
    let harness: ServerHarness
    let step: HarnessLoginStep
    /// Returns an error message to display, or nil when accepted.
    let submitCode: (String) async -> String?
    let submitApiKey: (ServerHarnessAccount, ServerHarnessAuthMethod, String) async -> String?
    let cancel: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var input = ""
    @State private var isSubmitting = false
    @State private var errorText: String?
    @State private var copiedCode = false

    var body: some View {
        NavigationStack {
            Form {
                content

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(harness.name)
            .navigationBarTitleDisplayMode(.inline)
            .disabled(isSubmitting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { cancel() }
                }

                if needsSubmit {
                    ToolbarItem(placement: .confirmationAction) {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Button("Continue") { submit() }
                                .disabled(trimmedInput.isEmpty)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let browserURL {
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Waiting for sign-in…")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)

                    Button {
                        openURL(browserURL)
                    } label: {
                        Label("Open \(harness.name) Sign-in", systemImage: "safari")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(isSubmitting)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .flow(let flow) where flow.kind == "pasteCode":
            Section {
                TextField("Code", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.continue)
                    .onSubmit { submit() }
            } footer: {
                Text("Approve the request in your browser, then paste the code it shows you.")
            }

            if let url = flowURL(flow) {
                Section {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Open Browser", systemImage: "safari")
                    }
                }
            }

        case .flow(let flow) where flow.kind == "deviceCode":
            Section {
                LabeledContent("Code") {
                    HStack(spacing: 12) {
                        Text(flow.userCode ?? "")
                            .font(.headline.monospaced())
                            .textSelection(.enabled)
                        Button {
                            copyCode(flow.userCode ?? "")
                        } label: {
                            Image(systemName: copiedCode ? "checkmark" : "doc.on.doc")
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(copiedCode ? "Copied" : "Copy Code")
                    }
                }
            } footer: {
                Text("Copy this code, then open the sign-in page in your browser.")
            }

        case .flow:
            Section {
                Label("Finish signing in in your browser.", systemImage: "safari")
            }

        case .apiKey(_, let method):
            Section {
                SecureField("API key", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                    .submitLabel(.continue)
                    .onSubmit { submit() }
            } footer: {
                Text(method.description ?? "The key is stored only on this machine.")
            }
        }
    }

    private var trimmedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var needsSubmit: Bool {
        switch step {
        case .flow(let flow): flow.kind == "pasteCode"
        case .apiKey: true
        }
    }

    private var waitsForBrowser: Bool {
        guard case .flow(let flow) = step else { return false }
        return flow.kind != "pasteCode"
    }

    private var browserURL: URL? {
        guard case .flow(let flow) = step, flow.kind != "pasteCode" else { return nil }
        return flowURL(flow)
    }

    private func flowURL(_ flow: ServerHarnessAuthFlow) -> URL? {
        (flow.url ?? flow.verificationUrl).flatMap(URL.init(string:))
    }

    private func copyCode(_ code: String) {
        UIPasteboard.general.string = code
        copiedCode = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copiedCode = false
        }
    }

    private func submit() {
        guard !trimmedInput.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        errorText = nil
        Task {
            defer { isSubmitting = false }
            switch step {
            case .flow:
                errorText = await submitCode(trimmedInput)
            case .apiKey(let account, let method):
                errorText = await submitApiKey(account, method, trimmedInput)
            }
        }
    }
}
