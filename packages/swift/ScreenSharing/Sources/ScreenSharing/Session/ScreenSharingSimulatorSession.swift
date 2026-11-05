@MainActor
public protocol ScreenSharingSimulatorSession: ScreenSharingViewingSession {
  var simulator: any ScreenSharingMessageChannel<ScreenSharingSimulatorMessage> { get }
  func start(token: String) async throws
}
