import SwiftUI

struct SimulatorPostureButtons: View {
  let model: SimulatorPaneModel

  var body: some View {
    let state = model.deviceState
    ForEach(state?.postures ?? [], id: \.self) { posture in
      let selected = state?.posture == posture
      Button {
        model.setPosture(posture)
      } label: {
        Label {
          Text(posture.capitalized)
        } icon: {
          SimulatorPostureGlyph(posture: posture, selected: selected)
        }
      }
      .help(posture.capitalized)
      .accessibilityLabel(posture.capitalized)
      .accessibilityAddTraits(selected ? .isSelected : [])
    }
  }
}

struct SimulatorPostureGlyph: View {
  let posture: String
  let selected: Bool

  var body: some View {
    let tint = selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary)
    let size = Self.size(posture)
    ZStack {
      Outline(posture: posture)
        .fill(selected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear))
      Outline(posture: posture)
        .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
      Camera(posture: posture)
        .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
      if posture == "closed" {
        Circle().fill(tint).frame(width: 2.5, height: 2.5).position(x: size.width * 0.68, y: size.height * 0.26)
      }
    }
    .frame(width: size.width, height: size.height)
    .accessibilityHidden(true)
  }

  static func size(_ posture: String) -> CGSize {
    posture == "closed" ? CGSize(width: 12, height: 16) : CGSize(width: 20, height: 15)
  }

  private struct Outline: Shape {
    let posture: String

    func path(in rect: CGRect) -> Path {
      let r = rect.insetBy(dx: 0.75, dy: 0.75)
      switch posture {
      case "closed":
        let radius = r.width * 0.28
        var path = Path()
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
        path.addArc(
          tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: radius)
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        path.addArc(
          tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: radius)
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        path.closeSubpath()
        return path
      case "book":
        let dip = r.height * 0.1
        let radius = r.width * 0.12
        let top = [
          CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY + dip), CGPoint(x: r.maxX, y: r.minY),
        ]
        let bottom = [
          CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY - dip), CGPoint(x: r.minX, y: r.maxY),
        ]
        let corners = top + bottom
        var path = Path()
        path.move(to: CGPoint(x: (corners[0].x + corners[1].x) / 2, y: (corners[0].y + corners[1].y) / 2))
        for index in 1...corners.count {
          let corner = corners[index % corners.count]
          let next = corners[(index + 1) % corners.count]
          path.addArc(tangent1End: corner, tangent2End: next, radius: index % 3 == 1 ? 0.5 : radius)
        }
        path.closeSubpath()
        return path
      default:
        return Path(roundedRect: r, cornerRadius: r.width * 0.16, style: .continuous)
      }
    }
  }

  private struct Camera: Shape {
    let posture: String

    func path(in rect: CGRect) -> Path {
      var path = Path()
      guard posture != "closed" else { return path }
      let y = rect.minY + rect.height * 0.22
      let half = rect.width * 0.11
      path.move(to: CGPoint(x: rect.midX - half, y: y))
      path.addLine(to: CGPoint(x: rect.midX, y: posture == "book" ? y + rect.height * 0.06 : y))
      path.addLine(to: CGPoint(x: rect.midX + half, y: y))
      return path
    }
  }
}
