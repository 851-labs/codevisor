import Foundation

extension CloudAccountClient {
  static func emailAuthError(code: String?, status: Int) -> CloudAccountClientError? {
    if status == 429 { return .authenticationFailed("Too many attempts. Please wait a minute and try again.") }
    switch code {
    case "EMAIL_NOT_VERIFIED": return .emailNotVerified
    case "EMAIL_DELIVERY_FAILED": return .emailDeliveryFailed
    case "INVALID_EMAIL": return .authenticationFailed("Enter a valid email address.")
    case "INVALID_EMAIL_OR_PASSWORD", "INVALID_PASSWORD":
      return .authenticationFailed("The email or password is incorrect.")
    case "USER_ALREADY_EXISTS", "USER_ALREADY_EXISTS_USE_ANOTHER_EMAIL":
      return .authenticationFailed("An account already uses this email. Sign in or reset your password.")
    case "INVALID_OTP", "OTP_EXPIRED", "VERIFICATION_CODE_NOT_FOUND":
      return .authenticationFailed("That code is incorrect or expired. Try again or request a new code.")
    case "TOO_MANY_ATTEMPTS": return .authenticationFailed("Too many incorrect attempts. Request a new code.")
    case "PASSWORD_TOO_SHORT": return .authenticationFailed("Use at least 8 characters for your password.")
    case "PASSWORD_TOO_LONG": return .authenticationFailed("Use 128 characters or fewer for your password.")
    default: return nil
    }
  }
}
