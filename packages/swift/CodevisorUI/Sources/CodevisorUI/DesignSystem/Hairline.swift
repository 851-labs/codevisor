import SwiftUI

/// A horizontal rule one device pixel thick. `Divider` is a full point on
/// every display, which reads heavier than the edges around it on Retina.
public struct Hairline: View {
  private let color: Color
  @Environment(\.pixelLength) private var pixelLength

  public init(color: Color) {
    self.color = color
  }

  public var body: some View {
    color.frame(height: pixelLength)
  }
}
