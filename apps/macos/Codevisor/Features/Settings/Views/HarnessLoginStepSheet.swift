import AppKit
import CodevisorCore
import CodevisorUI
import SwiftUI

/// One sign-in attempt as its own focused modal step (HIG: a sheet does a
/// single task). The accounts list never grows inline flow UI; every kind
/// of exchange — paste-code, device-code, plain browser wait, API key —
/// renders here with one instruction, one input, and clear actions.
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

struct HarnessLoginStepSheet: View {
    let harness: ServerHarness
    let step: HarnessLoginStep
    /// Returns an error message to display, or nil when accepted.
    let submitCode: (String) async -> String?
    let submitApiKey: (ServerHarnessAccount, ServerHarnessAuthMethod, String) async -> String?
    let cancel: () -> Void

    @Environment(\.theme) private var theme
    @State private var input = ""
    @State private var isSubmitting = false
    @State private var errorText: String?
    @State private var copiedCode = false

    var body: some View {
        VStack(spacing: 16) {
            HarnessIcon(harnessId: harness.id, fallbackSymbolName: harness.symbolName, size: 36)
            Text("Sign in to \(harness.name)")
                .font(.title3.weight(.semibold))

            content

            if let errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(theme.statusError)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            actions
        }
        .padding(24)
        .frame(width: 400)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .flow(let flow) where flow.kind == "pasteCode":
            instruction("Approve the request in your browser, then paste the code it shows you.")
            TextField("Code", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            if let url = flowURL(flow) {
                Button("Open Browser") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.link)
            }

        case .flow(let flow) where flow.kind == "deviceCode":
            instruction("Copy this code, then open the sign-in page in your browser.")
            VStack(spacing: 8) {
                Text(flow.userCode ?? "")
                    .font(.system(.title2, design: .monospaced, weight: .semibold))
                    .textSelection(.enabled)
                Button {
                    copyCode(flow.userCode ?? "")
                } label: {
                    Label(
                        copiedCode ? "Copied" : "Copy Code",
                        systemImage: copiedCode ? "checkmark" : "doc.on.doc"
                    )
                }
                .buttonStyle(.bordered)
            }
            if let value = flow.verificationUrl, let url = URL(string: value) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open Browser", systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
            }
            waiting

        case .flow(let flow):
            instruction("Finish signing in in your browser.")
            if let url = flowURL(flow) {
                Button("Open Browser") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.link)
            }
            waiting

        case .apiKey(_, let method):
            instruction(method.description ?? "The key is stored only on this machine.")
            SecureField("API key", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
        }
    }

    private var actions: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { cancel() }
                .keyboardShortcut(.cancelAction)
            if needsSubmit {
                Button(isSubmitting ? "Verifying…" : "Continue") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || isSubmitting)
            }
        }
    }

    private var needsSubmit: Bool {
        switch step {
        case .flow(let flow): flow.kind == "pasteCode"
        case .apiKey: true
        }
    }

    private var waiting: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Waiting for sign-in…")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func instruction(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func flowURL(_ flow: ServerHarnessAuthFlow) -> URL? {
        (flow.url ?? flow.verificationUrl).flatMap(URL.init(string:))
    }

    private func copyCode(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copiedCode = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copiedCode = false
        }
    }

    private func submit() {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        errorText = nil
        Task {
            defer { isSubmitting = false }
            switch step {
            case .flow:
                errorText = await submitCode(value)
            case .apiKey(let account, let method):
                errorText = await submitApiKey(account, method, value)
            }
        }
    }
}
