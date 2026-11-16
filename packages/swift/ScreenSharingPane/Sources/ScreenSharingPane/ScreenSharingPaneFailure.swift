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
      switch ScreenSharingFailureAction(for: reason) {
      case .viewHere: .viewHere
      case .connect, .retry: .tryAgain
      case nil: nil
      }
  }
}
