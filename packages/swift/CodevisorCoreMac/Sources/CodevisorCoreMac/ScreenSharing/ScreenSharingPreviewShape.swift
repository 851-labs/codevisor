import CoreGraphics

public struct ScreenSharingPreviewShape: Equatable, Sendable {
  public static let widest: CGFloat = 2
  public static let tallest: CGFloat = 1
  public static let standard = ScreenSharingPreviewShape(picture: 16 / 10)

  public let picture: CGFloat

  public init(screen: CGSize?) {
    guard let screen, screen.width > 0, screen.height > 0, screen.width.isFinite, screen.height.isFinite else {
      self = Self.standard
      return
    }

    self.init(picture: screen.width / screen.height)
  }

  private init(picture: CGFloat) {
    self.picture = picture
  }

  public var card: CGFloat { min(max(picture, Self.tallest), Self.widest) }
}
