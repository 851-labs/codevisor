import Foundation

public enum CloudEmailAuthRequest: Equatable, Sendable {
  case signIn(email: String, password: String)
  case signUp(email: String, password: String)
  case verify(email: String, code: String)
  case resendVerification(email: String)
  case requestPasswordReset(email: String)
  case resetPassword(email: String, code: String, password: String)

  var payload: (path: String, body: [String: String]) {
    switch self {
    case let .signIn(email, password):
      ("sign-in/email", ["email": email, "password": password])
    case let .signUp(email, password):
      ("sign-up/email", ["email": email, "password": password, "name": String(email.prefix(while: { $0 != "@" }))])
    case let .verify(email, code):
      ("email-otp/verify-email", ["email": email, "otp": code])
    case let .resendVerification(email):
      ("email-otp/send-verification-otp", ["email": email, "type": "email-verification"])
    case let .requestPasswordReset(email):
      ("email-otp/request-password-reset", ["email": email])
    case let .resetPassword(email, code, password):
      ("email-otp/reset-password", ["email": email, "otp": code, "password": password])
    }
  }

  var returnsSession: Bool {
    switch self {
    case .signIn, .verify: true
    default: false
    }
  }
}

extension CloudAccountClient {
  public func emailAuthentication(_ request: CloudEmailAuthRequest) async throws -> String? {
    let payload = request.payload
    let (data, response) = try await perform(
      "/api/auth/\(payload.path)", method: "POST", body: JSONEncoder().encode(payload.body))
    return request.returnsSession ? try Self.sessionToken(fromHeader: response, body: data) : nil
  }
}

extension CloudAccountController {
  public var supportsEmailSignIn: Bool { authProviders?.contains("email") == true }

  public func authenticateEmail(_ request: CloudEmailAuthRequest, context: CloudAuthenticationContext) async throws {
    guard isCurrent(context), !Task.isCancelled else { throw CancellationError() }
    let token = try await client.emailAuthentication(request)
    guard isCurrent(context), !Task.isCancelled else { throw CancellationError() }
    if let token {
      try await completeAuthentication(token: token, context: context)
      if let lastError { throw CloudAccountClientError.authenticationFailed(lastError) }
    }
  }
}

extension CloudAccountClienting {
  public func emailAuthentication(_ request: CloudEmailAuthRequest) async throws -> String? {
    throw CloudAccountClientError.invalidResponse
  }
}
