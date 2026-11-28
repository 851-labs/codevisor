@MainActor
public protocol ScreenSharingTransport: AnyObject {
  func open(report: @escaping @MainActor (ScreenSharingTransportEvent) -> Void) async throws
  func monitor() async -> ScreenSharingAttemptEnd?
  func switchDisplay(to displayId: String) -> Bool
  var switchesDisplayByReconnecting: Bool { get }
  func close()
}

extension ScreenSharingTransport {
  public func switchDisplay(to displayId: String) -> Bool { false }

  public var switchesDisplayByReconnecting: Bool { false }
}
