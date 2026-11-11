import Foundation
import Security

public enum ChromeImportError: LocalizedError, Equatable {
  case denied
  case notFound
  case unreadable

  init(keychainStatus: OSStatus) {
    switch keychainStatus {
    case errSecItemNotFound: self = .notFound
    case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed: self = .denied
    default: self = .unreadable
    }
  }

  public var errorDescription: String? {
    switch self {
    case .denied: "Codevisor needs Keychain access to read Chrome’s sign-ins."
    case .notFound: "Chrome hasn’t saved any sign-ins on this Mac yet."
    case .unreadable: "Couldn’t read Chrome’s sign-ins."
    }
  }
}
