@MainActor
public protocol ScreenSharingTransport: AnyObject {
  func open(report: @escaping @MainActor (ScreenSharingTransportEvent) -> Void) async throws
  func monitor() async -> ScreenSharingAttemptEnd?
  func close()
}
