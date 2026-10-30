import AppKit
import CodevisorCore
import CodevisorUI
import SwiftUI

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
  let harnessName: String
  let step: HarnessLoginStep
  let submitCode: (String) async -> String?
  let submitApiKey: (ServerHarnessAccount, ServerHarnessAuthMethod, String) async -> String?
  let cancel: () -> Void

  @State private var input = ""
  @State private var isSubmitting = false
  @State private var errorText: String?
  @State private var copiedCode = false

  var body: some View {
    NavigationStack {
      VStack(spacing: 16) {
        content
        if let errorText {
          Text(errorText)
            .font(.callout)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .navigationTitle("Sign in to \(harnessName)")
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      SheetFooter(status: footerStatus) { actions }
    }
    .sheetSize(.step)
  }

  @ViewBuilder
  private var content: some View {
    switch step {
    case .flow(let flow) where flow.kind == "pasteCode":
      instruction("Approve the request in your browser, then paste the code it shows you.")
      TextField("Code", text: $input)
        .textFieldStyle(.roundedBorder)
        .onSubmit { submit() }

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

    case .flow:
      instruction("Finish signing in in your browser.")

    case .apiKey(_, let method):
      instruction(method.description ?? "The key is stored only on this machine.")
      SecureField("API key", text: $input)
        .textFieldStyle(.roundedBorder)
        .onSubmit { submit() }
    }
  }

  @ViewBuilder
  private var actions: some View {
    Button("Cancel", role: .cancel) { cancel() }
      .keyboardShortcut(.cancelAction)
      .disabled(isSubmitting)
      .accessibilityLabel("Cancel sign-in")
    if let browserURL {
      Button("Open Browser") { NSWorkspace.shared.open(browserURL) }
        .keyboardShortcut(needsSubmit ? nil : .defaultAction)
    }
    if needsSubmit {
      Button("Continue") { submit() }
        .keyboardShortcut(.defaultAction)
        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
    }
  }

  private var footerStatus: String? {
    if isSubmitting { return "Verifying…" }
    return isAwaitingBrowser ? "Waiting for sign-in…" : nil
  }

  private var isAwaitingBrowser: Bool {
    guard case .flow(let flow) = step else { return false }
    return flow.kind != "pasteCode"
  }

  private var needsSubmit: Bool {
    switch step {
    case .flow(let flow): flow.kind == "pasteCode"
    case .apiKey: true
    }
  }

  private var browserURL: URL? {
    guard case .flow(let flow) = step else { return nil }
    return (flow.url ?? flow.verificationUrl).flatMap(URL.init(string:))
  }

  private func instruction(_ text: String) -> some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
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
