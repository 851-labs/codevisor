import CodevisorCore
import SwiftUI
import UIKit

/// One sign-in attempt as its own focused sheet, mirroring the macOS
/// HarnessLoginStepSheet: one instruction, one input, clear actions.
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                HarnessIconView(harnessId: harness.id, fallbackSymbolName: harness.symbolName, size: 44)
                    .padding(.top, 12)
                Text("Sign in to \(harness.name)")
                    .font(.title3.weight(.semibold))

                content

                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if needsSubmit {
                    Button {
                        submit()
                    } label: {
                        Text(isSubmitting ? "Verifying…" : "Continue")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || isSubmitting)
                }
                Spacer()
            }
            .padding(20)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .flow(let flow) where flow.kind == "pasteCode":
            instruction("Approve the request in your browser, then paste the code it shows you.")
            TextField("Code", text: $input)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { submit() }
            if let url = flowURL(flow) {
                Button("Open the browser again") { openURL(url) }
                    .font(.callout)
            }

        case .flow(let flow) where flow.kind == "deviceCode":
            instruction("Enter this code in your browser to continue.")
            HStack(spacing: 10) {
                Text(flow.userCode ?? "")
                    .font(.system(.title2, design: .monospaced, weight: .semibold))
                    .textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = flow.userCode ?? ""
                } label: {
                    Image(systemName: "doc.on.doc")
                }
            }
            if let value = flow.verificationUrl, let url = URL(string: value) {
                Button("Open the browser again") { openURL(url) }
                    .font(.callout)
            }
            waiting

        case .flow(let flow):
            instruction("Finish signing in in your browser.")
            if let url = flowURL(flow) {
                Button("Open the browser again") { openURL(url) }
                    .font(.callout)
            }
            waiting

        case .apiKey(_, let method):
            instruction(method.description ?? "The key is stored only on this machine.")
            SecureField("API key", text: $input)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { submit() }
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
            ProgressView()
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
