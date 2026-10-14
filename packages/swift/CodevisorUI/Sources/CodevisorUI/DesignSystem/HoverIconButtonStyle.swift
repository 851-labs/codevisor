import SwiftUI

public struct HoverIconButtonStyle: ButtonStyle {
  public enum HighlightShape: Shape {
    case circle
    case roundedRectangle
    case chip

    public func path(in rect: CGRect) -> Path {
      switch self {
      case .circle: Circle().path(in: rect)
      case .roundedRectangle: RoundedRectangle(cornerRadius: 6, style: .continuous).path(in: rect)
      case .chip: Capsule().path(in: rect)
      }
    }

    fileprivate var chipInsets: CGSize {
      self == .chip ? HoverIconButtonStyle.chipOverflow : .zero
    }
  }

  var shape: HighlightShape = .circle

  public static let chipOverflow = CGSize(width: 5, height: 3)

  public init(shape: HighlightShape = .circle) {
    self.shape = shape
  }

  public func makeBody(configuration: Configuration) -> some View {
    HoverIconButtonBody(configuration: configuration, shape: shape)
  }
}

private struct HoverIconButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let shape: HoverIconButtonStyle.HighlightShape
  @State private var isHovered = false

  public var body: some View {
    configuration.label
      .padding(.horizontal, chipInsets.width + edgePadding)
      .padding(.vertical, chipInsets.height + edgePadding)
      .frame(minHeight: shape == .chip ? 26 : nil)
      .background(shape.fill(isHovered ? Color.primary.opacity(0.06) : .clear))
      .contentShape(Rectangle())
      .onHover { isHovered = $0 }
      .opacity(configuration.isPressed ? 0.8 : 1)
  }

  private var edgePadding: CGFloat {
    shape == .circle ? 0 : 1
  }

  private var chipInsets: CGSize {
    shape.chipInsets
  }
}

extension View {
  public func hoverChipOverflow() -> some View {
    padding(.horizontal, -HoverIconButtonStyle.chipOverflow.width)
      .padding(.vertical, -HoverIconButtonStyle.chipOverflow.height)
  }
}
