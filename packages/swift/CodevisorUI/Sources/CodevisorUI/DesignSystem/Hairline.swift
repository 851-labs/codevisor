import SwiftUI

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
