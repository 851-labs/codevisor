import SwiftUI

/// A foldable at a hinge angle, as Device Hub draws it: the open device's two halves tilted
/// toward you about the hinge, and, folding past a book, its left half swung over the right
/// until the cover screen (the panel's back) lies on top. Book and open are drawn live; folding
/// shut or open animates `hinge` over stills.
struct SimulatorFoldScene<Inner: View, Outer: View>: View, Animatable {
  /// Degrees open: 0 closed, 130 a book, 180 flat.
  var hinge: Double
  /// The open device, flat, as it's presented (its inner screen sideways in the hand), in
  /// points at the scale it's drawn.
  let size: CGSize
  /// The hinge's x in `size`.
  let hingeX: CGFloat
  /// The closed device as presented, and where its hinge edge is in it.
  let coverSize: CGSize
  let coverHingeX: CGFloat
  /// The open device for one half (0 left, 1 right); each half is its own copy so a live screen
  /// can be drawn twice.
  /// The device's drop shadow: each half casts its own, kept to its side of the hinge so it
  /// doesn't fall across the other half.
  let shadowRadius: CGFloat
  @ViewBuilder let inner: (Int) -> Inner
  @ViewBuilder let cover: () -> Outer

  nonisolated var animatableData: Double {
    get { hinge }
    set { hinge = newValue }
  }

  var body: some View {
    let angles = SimulatorFold.angles(hinge: hinge)
    let depth = SimulatorFold.depth(width: size.width)
    let center = CGPoint(x: hingeX, y: size.height / 2)
    let coverX = hingeX - coverHingeX
    let shift = SimulatorFold.closing(hinge: hinge) * (size.width / 2 - (coverX + coverSize.width / 2))
    ZStack(alignment: .topLeading) {
      shadowed(
        inner(1)
          .clipShape(Half(hingeX: hingeX, left: false))
          .projectionEffect(SimulatorFold.tilt(angles.right, left: false, center: center, depth: depth)),
        left: false)
      if angles.left <= 90 {
        shadowed(
          inner(0)
            .clipShape(Half(hingeX: hingeX, left: true))
            .projectionEffect(SimulatorFold.tilt(angles.left, left: true, center: center, depth: depth)),
          left: true)
      } else {
        // Past upright the panel shows its back, the cover screen, coming down on the right.
        cover()
          .frame(width: coverSize.width, height: coverSize.height)
          .offset(x: coverX, y: (size.height - coverSize.height) / 2)
          .projectionEffect(SimulatorFold.tilt(180 - angles.left, left: false, center: center, depth: depth))
          .shadow(color: .black.opacity(0.35), radius: shadowRadius, y: shadowRadius * 0.4)
      }
    }
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    .offset(x: shift)
  }

  private func shadowed(_ half: some View, left: Bool) -> some View {
    half
      .shadow(color: .black.opacity(0.35), radius: shadowRadius, y: shadowRadius * 0.4)
      .clipShape(Half(hingeX: hingeX, left: left))
  }

  /// One side of the hinge, reaching past the device so its buttons stay in.
  private struct Half: Shape {
    let hingeX: CGFloat
    let left: Bool

    func path(in rect: CGRect) -> Path {
      let reach: CGFloat = 10_000
      return Path(
        left
          ? CGRect(x: -reach, y: -reach, width: hingeX + reach, height: rect.height + reach * 2)
          : CGRect(x: hingeX, y: -reach, width: reach, height: rect.height + reach * 2))
    }
  }
}

/// The geometry of a fold: how far each half turns at a hinge angle, and the perspective it's
/// drawn in.
enum SimulatorFold {
  /// Device Hub draws a book shallower than its hinge: each half tilts three quarters as far.
  static let bookTilt = 0.75

  /// How far each half is turned toward you from flat, in degrees. Between flat and a book both
  /// halves tilt alike; closing further the right half settles back flat while the left swings
  /// on over it, to 180 where it lies shut.
  nonisolated static func angles(hinge: Double) -> (left: Double, right: Double) {
    let hinge = min(180, max(0, hinge))
    let book = (180 - 130) / 2 * bookTilt
    if hinge >= 130 {
      let tilt = (180 - hinge) / 2 * bookTilt
      return (tilt, tilt)
    }
    let closing = 1 - hinge / 130
    return (book + (180 - book) * closing, book * (1 - closing))
  }

  /// 0 from flat to a book, rising to 1 shut: how far the device has moved to center the cover.
  nonisolated static func closing(hinge: Double) -> Double {
    hinge >= 130 ? 0 : 1 - max(0, hinge) / 130
  }

  /// The eye's distance, in widths of the open device: far enough that a book's edges lift only
  /// a little, as in Device Hub.
  nonisolated static func depth(width: CGFloat) -> CGFloat { width * 3 }

  /// A half turned `degrees` about the vertical hinge through `center`, its far edge toward
  /// you, seen in perspective from `depth` away: the plane's projection, as a 3×3 transform.
  nonisolated static func tilt(_ degrees: Double, left: Bool, center: CGPoint, depth: CGFloat) -> ProjectionTransform {
    let radians = degrees * .pi / 180
    let c = cos(radians)
    // A point `a` from the hinge comes toward you by |a|·sin, so it's drawn larger by
    // 1 / (1 + a·σ / depth), σ = sin on the left (a < 0) and -sin on the right.
    let sigma = (left ? 1 : -1) * sin(radians) / depth
    let cx = center.x, cy = center.y
    // Row vectors, as CGAffineTransform: (x, y, 1)·M = (X·w, Y·w, w).
    var transform = ProjectionTransform()
    transform.m11 = c + cx * sigma
    transform.m12 = cy * sigma
    transform.m13 = sigma
    transform.m21 = 0
    transform.m22 = 1
    transform.m23 = 0
    transform.m31 = cx - c * cx - cx * cx * sigma
    transform.m32 = -cx * cy * sigma
    transform.m33 = 1 - cx * sigma
    return transform
  }

  /// Where a point drawn on a tilted half lies on the flat device: `tilt`'s inverse, for touches.
  nonisolated static func flatten(
    _ point: CGPoint, hinge: Double, center: CGPoint, depth: CGFloat
  ) -> CGPoint {
    let angles = angles(hinge: hinge)
    let left = point.x < center.x
    let radians = (left ? angles.left : angles.right) * .pi / 180
    guard radians > 0, radians < .pi / 2 else { return point }
    let c = cos(radians), s = sin(radians)
    // Drawn `u` from the hinge, a point `d` out on the half: u = d·c / (1 - d·s / depth).
    let u = abs(point.x - center.x)
    let d = u / (c + u * s / depth)
    let w = 1 - d * s / depth
    return CGPoint(x: center.x + (left ? -d : d), y: center.y + (point.y - center.y) * w)
  }
}
