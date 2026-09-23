import AppKit
import CodevisorCore
import CodevisorUI
import SwiftUI

/// One sign-in attempt as a focused step. The accounts list never grows
/// inline flow UI; every kind of exchange — paste-code, device-code, plain
/// browser wait, API key — renders here with one instruction, one input,
/// and clear actions.
///
/// Presented as its own sheet. A pushed version was tried and reverted:
/// running the navigation transition inside AppKit's layout pass let an
/// `@Observable` model mutation land mid-layout, and AppKit raised from
/// `_postWindowNeedsUpdateConstraints`. Revisit only with that settled.
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
    NavigationStack {
      VStack(spacing: 16) {
        content
        if let errorText {
          Text(errorText)
            .font(.callout)
            .foregroundStyle(theme.statusError)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(20)
      // Hug the top so the footer sits on the sheet's bottom edge rather
      // than floating directly under the content.
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .navigationTitle("Sign in to \(harness.name)")
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      SheetFooter(status: footerStatus) { actions }
    }
    .sheetSize(.step)
    .themedSurface(.sheet)
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
        // Stays in the body because it acts on the body's content rather
        // than advancing the task. The step's primary lives in the footer.
        Button {
          copyCode(flow.userCode ?? "")
        } label: {
          Label(
            copiedCode ? "Copied" : "Copy Code",
            systemImage: copiedCode ? "checkmark" : "doc.on.doc"
          )
        }
        .buttonStyle(.bordered)
        .settingsActionTint(theme)
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

  /// Every action lives here, so exactly one button in the sheet carries
  /// `.defaultAction` and nothing in the body competes to look primary.
  @ViewBuilder
  private var actions: some View {
    Button("Cancel", role: .cancel) { cancel() }
      .settingsActionTint(theme)
      .keyboardShortcut(.cancelAction)
      .disabled(isSubmitting)
      .accessibilityLabel("Cancel sign-in")
    if let browserURL {
      Button("Open Browser") { NSWorkspace.shared.open(browserURL) }
        .settingsActionTint(theme)
        // Primary only when there is nothing to type: a paste-code step's
        // primary is Continue.
        .keyboardShortcut(needsSubmit ? nil : .defaultAction)
    }
    if needsSubmit {
      // No "Verifying…" title swap — a button that changes width mid-flight
      // shifts everything beside it. The footer's status slot says so.
      Button("Continue") { submit() }
        .settingsActionTint(theme)
        .keyboardShortcut(.defaultAction)
        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
    }
  }

  /// Every in-progress indicator in this family renders in the sheet's
  /// chrome, never in the body — including the browser wait. The body of a
  /// device-code step already carries the code and its copy action; a
  /// spinner among them is status about a background poll, not content.
  private var footerStatus: String? {
    if isSubmitting { return "Verifying…" }
    return isAwaitingBrowser ? "Waiting for sign-in…" : nil
  }

  /// Device-code and plain browser steps poll while the user finishes in
  /// their browser. A paste-code step is waiting on input here instead, so
  /// it has nothing in flight to report.
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

  /// The step's browser destination, if it has one.
  private var browserURL: URL? {
    guard case .flow(let flow) = step else { return nil }
    return (flow.url ?? flow.verificationUrl).flatMap(URL.init(string:))
  }

  private func instruction(_ text: String) -> some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(theme.textSecondary)
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
