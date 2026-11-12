enum MachineDesktopRegistration: Equatable {
  case pending
  case registered
  case failed(String)
}
