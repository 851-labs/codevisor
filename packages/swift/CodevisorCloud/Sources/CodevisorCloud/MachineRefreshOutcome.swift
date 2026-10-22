import Foundation

enum MachineRefreshOutcome {
  case succeeded
  case failed(any Error)
  case skipped

  var needsValidationRetry: Bool {
    guard case let .failed(error) = self else { return false }
    return !CloudSessionValidation.isSessionRejection(error)
  }
}
