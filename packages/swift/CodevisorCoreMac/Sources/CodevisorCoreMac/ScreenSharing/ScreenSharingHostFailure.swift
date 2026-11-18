import CodevisorClient
import Foundation
import ScreenCaptureKit
import ScreenSharing

struct ScreenSharingHostFailure {
  let error: any Error

  init(_ error: any Error) {
    self.error = error
  }

  var isRefusedCapture: Bool {
    let system = error as NSError
    return system.domain == SCStreamErrorDomain && system.code == SCStreamError.Code.userDeclined.rawValue
  }

  var sentence: String? {
    switch error {
    case ScreenSharingError.unavailable(let sentence), ScreenSharingError.invalid(let sentence): sentence
    case let failure as SimulatorRuntime.Failure: failure.message
    default: nil
    }
  }

  var code: String {
    let system = error as NSError
    return "\(system.domain) \(system.code)"
  }

  func reply(status: String) -> ServerScreenSharingReply {
    if isRefusedCapture { return ScreenSharingHostRefusal.permissionMissing.reply }

    return ServerScreenSharingReply(status: status, message: sentence)
  }
}
