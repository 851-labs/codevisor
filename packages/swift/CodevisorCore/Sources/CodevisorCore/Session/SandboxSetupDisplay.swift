import Foundation

@MainActor
protocol SandboxSetupDisplay: AnyObject {
  func showSetupStatus(_ text: String)
  func beginSetupPhase(_ phase: SessionSetupPhase)
  func mutateSetupPhase(id: String, _ transform: (inout SessionSetupPhase) -> Void)
}

extension SessionController: SandboxSetupDisplay {
  func showSetupStatus(_ text: String) {
    status = .connecting(text)
  }
}
