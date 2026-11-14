import Foundation

@MainActor
public final class ScreenSharingSurface: Identifiable {
  public nonisolated let id: UUID
  public let kind: ScreenSharingSurfaceKind
  public let connection: ScreenSharingConnection

  init(id: UUID, kind: ScreenSharingSurfaceKind, connection: ScreenSharingConnection) {
    self.id = id
    self.kind = kind
    self.connection = connection
  }

  isolated deinit {
    connection.detach(id)
  }

  public var isAttached: Bool { connection.surface(id) != nil }

  public var isOnScreen: Bool { connection.surface(id)?.isOnScreen == true }

  public var size: ScreenSharingSurfaceSize? {
    get { connection.surface(id)?.size }
    set { connection.setSize(newValue, for: id) }
  }

  public func setOnScreen(_ onScreen: Bool) {
    connection.setOnScreen(onScreen, for: id)
  }

  public func openedByUser() {
    guard kind.opensTheDesktop else { return }

    connection.openRequested(by: id)
  }

  public func retry() {
    guard isAttached else { return }

    connection.retryRequested()
  }

  public func viewHere() { retry() }

  public func detach() {
    connection.detach(id)
  }
}
