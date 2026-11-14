import Foundation

public struct ScreenSharingSurfaceState: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let kind: ScreenSharingSurfaceKind
  public internal(set) var isOnScreen = false
  public internal(set) var size: ScreenSharingSurfaceSize?
}
