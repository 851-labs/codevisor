import CoreGraphics
import SwiftUI

public struct ComputerUseCursorGlyph: View {
  let tint: Color
  let scale: CGFloat

  public init(tint: Color, scale: CGFloat = 1) {
    self.tint = tint
    self.scale = scale
  }

  public var body: some View {
    let size = ComputerUseCursorGlyphShape.size(scale: scale)
    let tip = ComputerUseCursorGlyphShape.tip(scale: scale)
    let shape = ComputerUseCursorGlyphShape()
    shape
      .fill(tint.opacity(0.94))
      .overlay {
        shape.stroke(
          Color(white: 0.90, opacity: 0.92),
          style: StrokeStyle(lineWidth: 1.25 * scale, lineCap: .round, lineJoin: .round)
        )
      }
      .shadow(color: .black.opacity(0.18), radius: 1.6 * scale, y: 0.35 * scale)
      .frame(width: size.width, height: size.height)
      .offset(x: size.width / 2 - tip.x, y: size.height / 2 - tip.y)
  }
}

struct ComputerUseCursorGlyphShape: Shape {
  static func size(scale: CGFloat) -> CGSize {
    CGSize(
      width: ComputerUseCursorMetrics.pointerSize.width * scale,
      height: ComputerUseCursorMetrics.pointerSize.height * scale
    )
  }

  static func tip(scale: CGFloat) -> CGPoint {
    let size = size(scale: scale)
    let artwork = computerUsePointerArtwork(size: size)
    return CGPoint(x: artwork.tip.x, y: size.height - artwork.tip.y)
  }

  func path(in rect: CGRect) -> Path {
    let artwork = computerUsePointerArtwork(size: rect.size)
    var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: rect.minX, ty: rect.maxY)
    return Path(artwork.cgPath.copy(using: &flip) ?? artwork.cgPath)
  }
}
