import Foundation
import Observation

/// Shared native form state. Passwords and codes live only for the lifetime of the sheet.
@MainActor
@Observable
public final class CloudEmailAuthModel {
  public enum Step: Hashable, Sendable {
    case signIn, signUp, verifyEmail, forgotPassword, resetPassword, passwordReset
  }

  public var email = ""
  public var password = ""
  public var code = ""
  public private(set) var navigationPath: [Step] = []
  public var step: Step { navigationPath.last ?? .signIn }
  public private(set) var isBusy = false
  public private(set) var errorMessage: String?
  public private(set) var notice: String?
  public private(set) var isComplete = false
  private let cloud: CloudAccountController
  private var context: CloudAuthenticationContext?
  private var requestRevision = 0

  public init(cloud: CloudAccountController) {
    self.cloud = cloud
    context = try? cloud.authenticationContext(link: false)
  }

  public var normalizedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
  public var validEmail: Bool {
    let parts = normalizedEmail.split(separator: "@", omittingEmptySubsequences: false)
    return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
      && !normalizedEmail.contains(where: \.isWhitespace) && normalizedEmail.count <= 254
  }
  public var validCode: Bool { code.count == 6 && code.allSatisfy { $0.isASCII && $0.isNumber } }
  public var canSubmit: Bool {
    guard !isBusy else { return false }
    switch step {
    case .signIn: return validEmail && !password.isEmpty
    case .signUp: return validEmail && (8...128).contains(password.count)
    case .verifyEmail: return validCode
    case .forgotPassword: return validEmail
    case .resetPassword: return validCode && (8...128).contains(password.count)
    case .passwordReset: return true
    }
  }

  public func navigate(to step: Step) {
    guard !isBusy else { return }
    setNavigationPath(step == .signIn ? [] : [step])
  }

  public func setNavigationPath(_ path: [Step]) {
    guard path != navigationPath else { return }
    requestRevision += 1
    isBusy = false
    navigationPath = path
    password = ""
    code = ""
    errorMessage = nil
    notice = nil
  }

  public func cancel() {
    context = nil
    requestRevision += 1
    isBusy = false
    password = ""
    code = ""
  }

  public func submit() async {
    guard canSubmit, !Task.isCancelled, let context else { return }
    if step == .passwordReset {
      navigate(to: .signIn)
      return
    }
    let revision = requestRevision
    isBusy = true
    errorMessage = nil
    notice = nil
    defer { if revision == requestRevision { isBusy = false } }
    do {
      switch step {
      case .signIn:
        do {
          try await cloud.authenticateEmail(.signIn(email: normalizedEmail, password: password), context: context)
          isComplete = true
        } catch CloudAccountClientError.emailNotVerified {
          guard revision == requestRevision, !Task.isCancelled else { return }
          navigationPath.append(.verifyEmail)
          password = ""
          try await cloud.authenticateEmail(.resendVerification(email: normalizedEmail), context: context)
        }
      case .signUp:
        // A failed delivery may leave a pending account. Keep the code screen available for resending.
        do {
          try await cloud.authenticateEmail(.signUp(email: normalizedEmail, password: password), context: context)
        } catch CloudAccountClientError.emailDeliveryFailed {
          guard revision == requestRevision, !Task.isCancelled else { return }
          navigationPath.append(.verifyEmail)
          password = ""
          throw CloudAccountClientError.emailDeliveryFailed
        }
        password = ""
        navigationPath.append(.verifyEmail)
      case .verifyEmail:
        try await cloud.authenticateEmail(.verify(email: normalizedEmail, code: code), context: context)
        isComplete = true
      case .forgotPassword:
        try await cloud.authenticateEmail(.requestPasswordReset(email: normalizedEmail), context: context)
        password = ""
        code = ""
        navigationPath.append(.resetPassword)
      case .resetPassword:
        try await cloud.authenticateEmail(
          .resetPassword(email: normalizedEmail, code: code, password: password), context: context)
        password = ""
        code = ""
        navigationPath = [.passwordReset]
      case .passwordReset: break
      }
      if isComplete { password = ""; code = "" }
    } catch is CancellationError {
      return
    } catch {
      guard revision == requestRevision, !Task.isCancelled, self.context != nil, cloud.isCurrent(context) else {
        return
      }
      errorMessage = error.localizedDescription
    }
  }

  public func resend() async {
    guard !isBusy, !Task.isCancelled, let context, step == .verifyEmail || step == .resetPassword else { return }
    let revision = requestRevision
    isBusy = true
    errorMessage = nil
    notice = nil
    defer { if revision == requestRevision { isBusy = false } }
    do {
      let request: CloudEmailAuthRequest =
        step == .verifyEmail
        ? .resendVerification(email: normalizedEmail) : .requestPasswordReset(email: normalizedEmail)
      try await cloud.authenticateEmail(request, context: context)
      code = ""
      notice = "A new code is on its way."
    } catch is CancellationError {
      return
    } catch {
      guard revision == requestRevision, !Task.isCancelled, self.context != nil, cloud.isCurrent(context) else {
        return
      }
      errorMessage = error.localizedDescription
    }
  }
}
