import CodevisorCore
import SwiftUI

public struct CloudEmailAuthSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var model: CloudEmailAuthModel
  @State private var action: Task<Void, Never>?

  public init(cloud: CloudAccountController) {
    _model = State(initialValue: CloudEmailAuthModel(cloud: cloud))
  }

  public var body: some View {
    Group {
      #if os(iOS)
        NavigationStack(path: Binding(get: { model.navigationPath }, set: navigate)) {
          page(.signIn)
            .navigationDestination(for: CloudEmailAuthModel.Step.self) { page($0) }
        }
        .tint(.blue)
      #else
        page(model.step).id(model.step)
      #endif
    }
    .onChange(of: model.isComplete) { _, complete in if complete { dismiss() } }
    .onDisappear {
      action?.cancel()
      model.cancel()
    }
  }

  private func page(_ step: CloudEmailAuthModel.Step) -> some View {
    CloudEmailAuthPage(
      model: model, step: step, cancelAction: { dismiss() },
      submitAction: { action = Task { await model.submit() } },
      resendAction: { action = Task { await model.resend() } },
      navigate: navigate
    )
  }

  private func navigate(_ path: [CloudEmailAuthModel.Step]) {
    guard path != model.navigationPath else { return }
    action?.cancel()
    model.setNavigationPath(path)
  }
}

struct CloudEmailAuthPage: View {
  @Environment(\.theme) var theme
  @Bindable var model: CloudEmailAuthModel
  let step: CloudEmailAuthModel.Step
  let cancelAction: () -> Void
  let submitAction: () -> Void
  let resendAction: () -> Void
  let navigate: ([CloudEmailAuthModel.Step]) -> Void
  @FocusState private var focus: Field?
  private enum Field: Hashable { case email, password, code }

  var body: some View {
    platformBody
      .onAppear {
        if step != .signIn {
          focus = step == .verifyEmail || step == .resetPassword ? .code : .email
        }
      }
  }

  var submitButton: some View {
    Button(actionTitle, action: submit)
      .disabled(!model.canSubmit)
      .accessibilityIdentifier("emailAuth.submit")
  }

  var termsNotice: some View {
    Text(
      "By creating an account, you agree to our [Terms of Service](https://www.codevisor.dev/terms) and acknowledge our [Privacy Policy](https://www.codevisor.dev/privacy)."
    )
  }

  var successMessage: some View {
    Label("Sign in with your new password.", systemImage: "checkmark.circle")
  }

  @ViewBuilder
  var statusMessages: some View {
    if let message = model.errorMessage {
      Text(message).font(.callout).foregroundStyle(theme.statusError)
    }
    if let notice = model.notice {
      Text(notice).font(.callout).foregroundStyle(.secondary)
    }
  }

  var fields: some View {
    Group {
      if step == .signIn || step == .signUp || step == .forgotPassword {
        input("Email") {
          TextField("Email", text: $model.email, prompt: Text("you@example.com"))
            .textContentType(.emailAddress)
            .focused($focus, equals: .email)
            #if os(iOS)
              .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
              .submitLabel(step == .forgotPassword ? .send : .next)
            #endif
            .accessibilityIdentifier("emailAuth.email")
        }
      }
      if step == .verifyEmail || step == .resetPassword {
        input("Verification code") {
          TextField("Verification code", text: $model.code, prompt: Text("6-digit code"))
            .textContentType(.oneTimeCode)
            .focused($focus, equals: .code)
            #if os(iOS)
              .keyboardType(.numberPad)
            #endif
            .onChange(of: model.code) { _, value in
              model.code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
            }
            .accessibilityIdentifier("emailAuth.code")
        }
      }
      if step == .signIn || step == .signUp || step == .resetPassword {
        input(step == .resetPassword ? "New password" : "Password") {
          SecureField(
            "Password", text: $model.password,
            prompt: Text(step == .signIn ? "Password" : "At least 8 characters")
          )
          .textContentType(step == .signIn ? .password : .newPassword)
          .focused($focus, equals: .password)
          .accessibilityIdentifier("emailAuth.password")
          #if os(iOS)
            .submitLabel(.go)
          #endif
        }
      }
    }
    .disabled(model.isBusy)
    .onSubmit {
      if focus == .email && (step == .signIn || step == .signUp) {
        focus = .password
      } else {
        submit()
      }
    }
  }

  private func input<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
    LabeledContent(label) {
      content()
        .labelsHidden()
        .accessibilityLabel(label)
        #if os(iOS)
          .multilineTextAlignment(.trailing)
        #else
          .textFieldStyle(.roundedBorder)
        #endif
    }
  }

  @ViewBuilder
  var secondaryButtons: some View {
    switch step {
    case .signIn:
      NavigationLink("Forgot password?", value: CloudEmailAuthModel.Step.forgotPassword)
      NavigationLink("Create an account", value: CloudEmailAuthModel.Step.signUp)
    case .verifyEmail, .resetPassword:
      Button("Resend code", action: resendAction)
    case .signUp, .forgotPassword, .passwordReset:
      EmptyView()
    }
  }

  var hasSecondaryActions: Bool { step == .signIn || step == .verifyEmail || step == .resetPassword }

  func submit() {
    guard model.canSubmit else { return }
    focus = nil
    submitAction()
  }

  var title: String {
    switch step {
    case .signIn: "Sign In"
    case .signUp: "Create Account"
    case .verifyEmail: "Verify Email"
    case .forgotPassword, .resetPassword: "Reset Password"
    case .passwordReset: "Password Updated"
    }
  }
  var subtitle: String? {
    switch step {
    case .signIn, .signUp, .passwordReset: nil
    case .verifyEmail: "Enter the code sent to \(model.normalizedEmail)."
    case .forgotPassword: "We'll email you a code to reset your password."
    case .resetPassword: "If an account exists for \(model.normalizedEmail), we've sent a code."
    }
  }
  var actionTitle: String {
    switch step {
    case .signIn, .passwordReset: return "Sign In"
    case .signUp: return "Create"
    case .verifyEmail: return "Verify"
    case .forgotPassword: return "Send"
    case .resetPassword: return "Reset"
    }
  }
}
