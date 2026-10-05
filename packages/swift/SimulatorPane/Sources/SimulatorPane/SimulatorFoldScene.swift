import SwiftUI

/// A foldable at a hinge angle, as Device Hub draws it: the open device's two halves tilted
/// toward you about the hinge, and, folding past a book, its left half swung over the right
/// until the cover screen (the panel's back) lies on top. Each half is a slab: its outer side
/// shows as it turns toward you, and faces darken as they turn away from the light.
struct SimulatorFoldScene<Inner: View, Outer: View>: View, Animatable {
  /// Degrees open: 0 closed, 130 a book, 180 flat.
  var hinge: Double
  /// The open device, flat, as it's presented (its inner screen sideways in the hand), in
  /// points at the scale it's drawn.
  let size: CGSize
  /// The hinge's x in `size`.
  let hingeX: CGFloat
  /// The open device's frame in `size`, and its corners' radius.
  let bezel: CGRect
  let cornerRadius: CGFloat
  /// The closed device as presented, and where its hinge edge is in it.
  let coverSize: CGSize
  let coverHingeX: CGFloat
  /// The closed device's frame in `coverSize`, and its corners' radius.
  let coverBezel: CGRect
  let coverCornerRadius: CGFloat
  /// The device's drop shadow: each half casts its own, kept to its side of the hinge so it
  /// doesn't fall across the other half.
  let shadowRadius: CGFloat
  /// The open device for one half (0 left, 1 right); each half is its own copy so a live screen
  /// can be drawn twice.
  @ViewBuilder let inner: (Int) -> Inner
  @ViewBuilder let cover: () -> Outer

  nonisolated var animatableData: Double {
    get { hinge }
    set { hinge = newValue }
  }

  /// How thick each half is: about a thirtieth of its height, as an iPhone Duo's halves are.
  private var thickness: CGFloat { bezel.height * SimulatorFold.thickness }

  var body: some View {
    let angles = SimulatorFold.angles(hinge: hinge)
    let depth = SimulatorFold.depth(width: size.width)
    let center = CGPoint(x: hingeX, y: size.height / 2)
    let coverX = hingeX - coverHingeX
    let coverY = (size.height - coverSize.height) / 2
    let shift = SimulatorFold.closing(hinge: hinge) * (size.width / 2 - (coverX + coverSize.width / 2))
    ZStack(alignment: .topLeading) {
      // Shut, the cover lies over the right half; it's kept (hidden) so its video is ready to open.
      Group {
        body(
          bezel, corners: .init(all: cornerRadius), clip: .right, from: 0, facing: angles.right
        ) { SimulatorFold.tilt(angles.right, left: false, center: center, depth: depth, inset: $0) }
        shadowed(
          inner(1)
            .overlay(alignment: .topLeading) {
              shade(SimulatorFold.shade(tilt: angles.right), in: bezel, radius: cornerRadius)
            }
            // A hair past the hinge, under the left half: two antialiased edges meeting exactly
            // would leave a dark seam down the middle.
            .clipShape(Half(hingeX: hingeX - Self.overlap, left: false))
            .projectionEffect(SimulatorFold.tilt(angles.right, left: false, center: center, depth: depth)),
          left: false
        )
      }
      .opacity(hinge > 0 ? 1 : 0)
      if angles.left <= 90 {
        body(
          bezel, corners: .init(all: cornerRadius), clip: .left, from: 0, facing: angles.left
        ) { SimulatorFold.tilt(angles.left, left: true, center: center, depth: depth, inset: $0) }
        shadowed(
          inner(0)
            .overlay(alignment: .topLeading) {
              shade(SimulatorFold.shade(tilt: angles.left), in: bezel, radius: cornerRadius)
            }
            .clipShape(Half(hingeX: hingeX, left: true))
            .projectionEffect(SimulatorFold.tilt(angles.left, left: true, center: center, depth: depth)),
          left: true)
      } else {
        // Past upright the panel shows its back, the cover screen, coming down on the right, a
        // panel's thickness above the half it closes on.
        let tilt = 180 - angles.left
        // The panel's body, from the inner face it closes with up to the cover on its back. The
        // cover's hinge edge is square; its other corners round as the device does.
        body(
          coverBezel.offsetBy(dx: coverX, dy: coverY),
          corners: .init(
            topLeft: coverCornerRadius * 0.15, topRight: coverCornerRadius, bottomRight: coverCornerRadius,
            bottomLeft: coverCornerRadius * 0.15),
          clip: nil, from: -thickness, facing: tilt
        ) { SimulatorFold.tilt(tilt, left: false, center: center, depth: depth, inset: $0) }
        cover()
          .frame(width: coverSize.width, height: coverSize.height)
          .overlay(alignment: .topLeading) {
            shade(SimulatorFold.shade(tilt: tilt), in: coverBezel, radius: coverCornerRadius)
          }
          .offset(x: coverX, y: coverY)
          .projectionEffect(
            SimulatorFold.tilt(tilt, left: false, center: center, depth: depth, inset: -thickness)
          )
          .shadow(color: .black.opacity(0.35), radius: shadowRadius, y: shadowRadius * 0.4)
      }
    }
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    .offset(x: shift)
  }

  /// A half's body through its thickness: the device's outline, `frame` with `corners`, from
  /// where its face sits (`from`) back a panel's thickness, each depth placed by `place`. The body
  /// is convex, so its silhouette is the hull of its front and back outlines: one smooth shape
  /// whose rim, left showing around the face drawn over it, joins the face and rounds its corners.
  private func body(
    _ frame: CGRect, corners: SimulatorFold.Corners, clip side: HalfSide?, from face: CGFloat, facing degrees: Double,
    place: (CGFloat) -> ProjectionTransform
  ) -> some View {
    var outline = SimulatorFold.outline(frame, corners: corners)
    if let side { outline = SimulatorFold.clip(outline, atX: hingeX - Self.overlap, keepingLeft: side == .left) }
    let front = place(face), back = place(face + thickness)
    let silhouette = SimulatorFold.hull(
      outline.map { SimulatorFold.apply(front, $0) } + outline.map { SimulatorFold.apply(back, $0) })
    let light = 1 - SimulatorFold.shade(tilt: abs(90 - degrees)) * 0.7
    return Path { path in
      path.addLines(silhouette); path.closeSubpath()
    }
    // A metal side, lighter than the black glass beside it.
    .fill(Color(white: 0.36 * light))
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    .allowsHitTesting(false)
  }

  private enum HalfSide { case left, right }

  /// A face turned away from the light, darkened over the device's outline.
  private func shade(_ amount: Double, in frame: CGRect, radius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
      .fill(.black.opacity(amount))
      .frame(width: frame.width, height: frame.height)
      .offset(x: frame.minX, y: frame.minY)
      .allowsHitTesting(false)
  }

  /// How far the right half reaches under the left one.
  private static var overlap: CGFloat { 1.5 }

  private func shadowed(_ half: some View, left: Bool) -> some View {
    half
      .shadow(color: .black.opacity(0.35), radius: shadowRadius, y: shadowRadius * 0.4)
      // The right half runs on under the left a hair past the hinge, but only alongside the
      // device: beyond it, where there's only drop shadow, the two shadows meet at the hinge
      // rather than doubling up.
      .clipShape(
        left
          ? Half(hingeX: hingeX, left: true)
          : Half(hingeX: hingeX, left: false, under: (Self.overlap, bezel.minY...bezel.maxY)))
  }

  /// One side of the hinge, reaching past the device so its buttons stay in.
  private struct Half: Shape {
    let hingeX: CGFloat
    let left: Bool
    /// The right half's reach past the hinge, and the rows it reaches there.
    var under: (width: CGFloat, rows: ClosedRange<CGFloat>)?

    func path(in rect: CGRect) -> Path {
      let reach: CGFloat = 10_000
      if let under, !left {
        var path = Path(CGRect(x: hingeX, y: -reach, width: reach, height: rect.height + reach * 2))
        path.addRect(
          CGRect(
            x: hingeX - under.width, y: under.rows.lowerBound, width: under.width + 1,
            height: under.rows.upperBound - under.rows.lowerBound))
        return path
      }
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

  /// Each half's thickness, as a fraction of the device's height.
  static let thickness: CGFloat = 0.03

  /// How much a face turned `tilt` degrees from facing you darkens, lit from the front.
  nonisolated static func shade(tilt: Double) -> Double {
    0.6 * (1 - cos(min(90, max(0, tilt)) * .pi / 180))
  }

  /// A half turned `degrees` about the vertical hinge through `center`, its far edge toward
  /// you, seen in perspective from `depth` away: the plane's projection, as a 3×3 transform.
  /// `inset` puts the plane that far behind the screen's surface (negative: in front of it).
  nonisolated static func tilt(
    _ degrees: Double, left: Bool, center: CGPoint, depth: CGFloat, inset: CGFloat = 0
  ) -> ProjectionTransform {
    let radians = degrees * .pi / 180
    let c = CGFloat(cos(radians)), s = CGFloat(sin(radians))
    let cx = center.x
    // A point x across the half, `inset` deep, turns about the hinge to (x', z) toward you.
    return left
      ? plane(x: (cx - cx * c - inset * s, c), y: 0, z: (cx * s - inset * c, -s), center: center, depth: depth)
      : plane(x: (cx - cx * c + inset * s, c), y: 0, z: (-cx * s - inset * c, s), center: center, depth: depth)
  }

  /// A rounded rectangle's corner radii.
  struct Corners {
    var topLeft: CGFloat, topRight: CGFloat, bottomRight: CGFloat, bottomLeft: CGFloat

    init(topLeft: CGFloat, topRight: CGFloat, bottomRight: CGFloat, bottomLeft: CGFloat) {
      (self.topLeft, self.topRight, self.bottomRight, self.bottomLeft) = (topLeft, topRight, bottomRight, bottomLeft)
    }

    init(all radius: CGFloat) { self.init(topLeft: radius, topRight: radius, bottomRight: radius, bottomLeft: radius) }
  }

  /// Points around a rounded rectangle with continuous corners, as the device's outline curves,
  /// close enough together to stay smooth.
  nonisolated static func outline(_ rect: CGRect, corners: Corners) -> [CGPoint] {
    let shape = UnevenRoundedRectangle(
      topLeadingRadius: corners.topLeft, bottomLeadingRadius: corners.bottomLeft,
      bottomTrailingRadius: corners.bottomRight, topTrailingRadius: corners.topRight, style: .continuous)
    var points: [CGPoint] = []
    shape.path(in: rect).cgPath.flattened(threshold: 0.25).applyWithBlock { element in
      switch element.pointee.type {
      case .moveToPoint, .addLineToPoint: points.append(element.pointee.points[0])
      default: break
      }
    }
    return points
  }

  /// A convex outline cut by the vertical line at `x`, keeping one side.
  nonisolated static func clip(_ points: [CGPoint], atX x: CGFloat, keepingLeft: Bool) -> [CGPoint] {
    func inside(_ point: CGPoint) -> Bool { keepingLeft ? point.x <= x : point.x >= x }
    var kept: [CGPoint] = []
    for (index, point) in points.enumerated() {
      let next = points[(index + 1) % points.count]
      if inside(point) { kept.append(point) }
      if inside(point) != inside(next), next.x != point.x {
        let t = (x - point.x) / (next.x - point.x)
        kept.append(CGPoint(x: x, y: point.y + (next.y - point.y) * t))
      }
    }
    return kept
  }

  /// Where `transform` draws `point`.
  nonisolated static func apply(_ transform: ProjectionTransform, _ point: CGPoint) -> CGPoint {
    let w = point.x * transform.m13 + point.y * transform.m23 + transform.m33
    return CGPoint(
      x: (point.x * transform.m11 + point.y * transform.m21 + transform.m31) / w,
      y: (point.x * transform.m12 + point.y * transform.m22 + transform.m32) / w)
  }

  /// The convex hull of `points`, in order around it (Andrew's monotone chain).
  nonisolated static func hull(_ points: [CGPoint]) -> [CGPoint] {
    let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
    guard sorted.count > 2 else { return sorted }
    func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
      (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }
    var lower: [CGPoint] = [], upper: [CGPoint] = []
    for point in sorted {
      while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 { lower.removeLast() }
      lower.append(point)
    }
    for point in sorted.reversed() {
      while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 { upper.removeLast() }
      upper.append(point)
    }
    return Array(lower.dropLast() + upper.dropLast())
  }

  /// A flat view placed in space, seen from `depth` in front of `center`: a point (u, v) of it
  /// lies at x = x.0 + x.1·u, y = y + v, z = z.0 + z.1·u (z toward you). Its perspective
  /// projection, in row vectors as CGAffineTransform: (u, v, 1)·M = (X·w, Y·w, w).
  nonisolated static func plane(
    x: (CGFloat, CGFloat), y: CGFloat, z: (CGFloat, CGFloat), center: CGPoint, depth: CGFloat
  ) -> ProjectionTransform {
    // Drawn scaled by depth / (depth - z) about the center: w = 1 - z / depth.
    let cx = center.x, cy = center.y
    var transform = ProjectionTransform()
    transform.m11 = x.1 - cx * z.1 / depth
    transform.m12 = -cy * z.1 / depth
    transform.m13 = -z.1 / depth
    transform.m21 = 0
    transform.m22 = 1
    transform.m23 = 0
    transform.m31 = x.0 - cx * z.0 / depth
    transform.m32 = y - cy * z.0 / depth
    transform.m33 = 1 - z.0 / depth
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
