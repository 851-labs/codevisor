import SwiftUI

struct SimulatorFoldScene<Inner: View, Outer: View>: View, Animatable {
  var hinge: Double
  let size: CGSize
  let hingeX: CGFloat
  let bezel: CGRect
  let cornerRadius: CGFloat
  let coverSize: CGSize
  let coverHingeX: CGFloat
  let coverBezel: CGRect
  let coverCornerRadius: CGFloat
  let shadowRadius: CGFloat
  @ViewBuilder let inner: (Int) -> Inner
  @ViewBuilder let cover: () -> Outer

  nonisolated var animatableData: Double {
    get { hinge }
    set { hinge = newValue }
  }

  private var thickness: CGFloat { bezel.height * SimulatorFold.thickness }

  var body: some View {
    let angles = SimulatorFold.angles(hinge: hinge)
    let depth = SimulatorFold.depth(width: size.width)
    let center = CGPoint(x: hingeX, y: size.height / 2)
    let coverX = hingeX - coverHingeX
    let coverY = (size.height - coverSize.height) / 2
    let shift = SimulatorFold.closing(hinge: hinge) * (size.width / 2 - (coverX + coverSize.width / 2))
    ZStack(alignment: .topLeading) {
      Group {
        body(
          bezel, corners: .init(all: cornerRadius), clip: .right, from: 0, facing: angles.right
        ) { SimulatorFold.tilt(angles.right, left: false, center: center, depth: depth, inset: $0) }
        shadowed(
          inner(1)
            .overlay(alignment: .topLeading) {
              shade(SimulatorFold.shade(tilt: angles.right), in: bezel, radius: cornerRadius)
            }
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
        let tilt = 180 - angles.left
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
    .fill(Color(white: 0.36 * light))
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    .allowsHitTesting(false)
  }

  private enum HalfSide { case left, right }

  private func shade(_ amount: Double, in frame: CGRect, radius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: radius, style: .continuous)
      .fill(.black.opacity(amount))
      .frame(width: frame.width, height: frame.height)
      .offset(x: frame.minX, y: frame.minY)
      .allowsHitTesting(false)
  }

  private static var overlap: CGFloat { 1.5 }

  private func shadowed(_ half: some View, left: Bool) -> some View {
    half
      .shadow(color: .black.opacity(0.35), radius: shadowRadius, y: shadowRadius * 0.4)
      .clipShape(
        left
          ? Half(hingeX: hingeX, left: true)
          : Half(hingeX: hingeX, left: false, under: (Self.overlap, bezel.minY...bezel.maxY)))
  }

  private struct Half: Shape {
    let hingeX: CGFloat
    let left: Bool
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

enum SimulatorFold {
  static let bookTilt = 0.75

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

  nonisolated static func closing(hinge: Double) -> Double {
    hinge >= 130 ? 0 : 1 - max(0, hinge) / 130
  }

  nonisolated static func depth(width: CGFloat) -> CGFloat { width * 3 }

  static let thickness: CGFloat = 0.03

  nonisolated static func shade(tilt: Double) -> Double {
    0.6 * (1 - cos(min(90, max(0, tilt)) * .pi / 180))
  }

  nonisolated static func tilt(
    _ degrees: Double, left: Bool, center: CGPoint, depth: CGFloat, inset: CGFloat = 0
  ) -> ProjectionTransform {
    let radians = degrees * .pi / 180
    let c = CGFloat(cos(radians)), s = CGFloat(sin(radians))
    let cx = center.x
    return left
      ? plane(x: (cx - cx * c - inset * s, c), y: 0, z: (cx * s - inset * c, -s), center: center, depth: depth)
      : plane(x: (cx - cx * c + inset * s, c), y: 0, z: (-cx * s - inset * c, s), center: center, depth: depth)
  }

  struct Corners {
    var topLeft: CGFloat, topRight: CGFloat, bottomRight: CGFloat, bottomLeft: CGFloat

    init(topLeft: CGFloat, topRight: CGFloat, bottomRight: CGFloat, bottomLeft: CGFloat) {
      (self.topLeft, self.topRight, self.bottomRight, self.bottomLeft) = (topLeft, topRight, bottomRight, bottomLeft)
    }

    init(all radius: CGFloat) { self.init(topLeft: radius, topRight: radius, bottomRight: radius, bottomLeft: radius) }
  }

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

  nonisolated static func apply(_ transform: ProjectionTransform, _ point: CGPoint) -> CGPoint {
    let w = point.x * transform.m13 + point.y * transform.m23 + transform.m33
    return CGPoint(
      x: (point.x * transform.m11 + point.y * transform.m21 + transform.m31) / w,
      y: (point.x * transform.m12 + point.y * transform.m22 + transform.m32) / w)
  }

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

  nonisolated static func plane(
    x: (CGFloat, CGFloat), y: CGFloat, z: (CGFloat, CGFloat), center: CGPoint, depth: CGFloat
  ) -> ProjectionTransform {
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

  nonisolated static func flatten(
    _ point: CGPoint, hinge: Double, center: CGPoint, depth: CGFloat
  ) -> CGPoint {
    let angles = angles(hinge: hinge)
    let left = point.x < center.x
    let radians = (left ? angles.left : angles.right) * .pi / 180
    guard radians > 0, radians < .pi / 2 else { return point }
    let c = cos(radians), s = sin(radians)
    let u = abs(point.x - center.x)
    let d = u / (c + u * s / depth)
    let w = 1 - d * s / depth
    return CGPoint(x: center.x + (left ? -d : d), y: center.y + (point.y - center.y) * w)
  }
}
