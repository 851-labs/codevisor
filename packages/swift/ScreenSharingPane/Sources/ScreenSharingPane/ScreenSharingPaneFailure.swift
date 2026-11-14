import ScreenSharingConnection

struct ScreenSharingPaneFailure: Equatable {
  enum Action: Equatable {
    case viewHere
    case tryAgain
  }

  let sentence: String
  let action: Action?

  init(reason: ScreenSharingFailureReason, machineName: String) {
    sentence = reason.sentence(on: machineName)
    action =
      switch reason {
      case .takenOver, .inUse: .viewHere
      case .unsupportedOnThisDevice: nil
      default: .tryAgain
      }
  }
}
