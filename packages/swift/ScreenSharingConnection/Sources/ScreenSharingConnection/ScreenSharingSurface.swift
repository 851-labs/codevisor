import Foundation

@MainActor
public final class ScreenSharingSurface: Identifiable {
  public nonisolated let id = UUID()
  public let kind: ScreenSharingSurfaceKind
  public let connection: ScreenSharingConnection
  public private(set) var isOnScreen = false
  public private(set) var isAttached = true
  public var size: ScreenSharingSurfaceSize?

  init(kind: ScreenSharingSurfaceKind, connection: ScreenSharingConnection) {
    self.kind = kind
    self.connection = connection
  }

  public func setOnScreen(_ onScreen: Bool) {
    guard isAttached, onScreen != isOnScreen else { return }

    isOnScreen = onScreen
    connection.surfacesChanged()
  }

  public func openedByUser() {
    guard isAttached, kind.opensTheDesktop else { return }

    connection.openRequested()
  }

  public func retry() {
    guard isAttached else { return }

    connection.retryRequested()
  }

  public func viewHere() { retry() }

  public func detach() {
    guard isAttached else { return }

    isAttached = false
    isOnScreen = false
    connection.detach(self)
  }
}
