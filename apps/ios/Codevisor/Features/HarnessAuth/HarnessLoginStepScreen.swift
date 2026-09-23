import CodevisorCore
import CodevisorUI
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
  @Environment(\.theme) private var theme
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
              .foregroundStyle(theme.statusError)
          }
        }
      }
      .navigationTitle(harness.name)
      .navigationBarTitleDisplayMode(.inline)
      .disabled(isSubmitting)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", systemImage: "xmark", role: .cancel) { cancel() }.labelStyle(.iconOnly)
            .disabled(isSubmitting)
        }

        // Mutually exclusive with the confirm item below: `browserURL` is
        // nil for exactly the steps that submit input, so the sheet never
        // shows two confirmation actions. Text, and prominent, because on a
        // device-code step this *is* the action that advances the task —
        // the same role its macOS counterpart has in the footer.
        if let browserURL {
          SheetConfirmToolbarItem("Open Browser", isEnabled: !isSubmitting) { openURL(browserURL) }
        }
        if needsSubmit {
          // Text, never a bare checkmark. Progress is the status bar's job.
          SheetConfirmToolbarItem(
            "Continue", isEnabled: !trimmedInput.isEmpty && !isSubmitting
          ) {
            submit()
          }
        }
      }
    }
    .sheetStatus(statusLabel)
    .presentationDetents([.medium, .large])
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

  /// The port of macOS `HarnessLoginStepSheet.footerStatus`, same wording:
  /// every in-progress indicator in this family renders in chrome, the
  /// browser wait included. The body of a device-code step already carries
  /// the code and its copy action; a spinner among them is status about a
  /// background poll, not content.
  private var statusLabel: String? {
    if isSubmitting { return "Verifying…" }
    return waitsForBrowser ? "Waiting for sign-in…" : nil
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

  /// Device-code and plain browser steps poll in the background; a
  /// paste-code step waits on input here instead.
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
