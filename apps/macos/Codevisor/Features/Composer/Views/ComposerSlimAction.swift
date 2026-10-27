enum ComposerSlimAction: Equatable {
  case stop(isCancelling: Bool)
  case send(isEnabled: Bool, isBusy: Bool, help: String)
}
