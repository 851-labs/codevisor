import CodevisorUI
import SwiftUI

enum QuestionOptionIndicator {
  case single
  case multiple
}

struct QuestionOptionRow: View {
  let title: String
  let description: String?
  let indicator: QuestionOptionIndicator
  let isSelected: Bool
  let action: () -> Void

  @Environment(\.theme) private var theme
  @State private var showsInfo = false
  private static let ringWidth: CGFloat = 1.5
  private let cardStyle = ComposerCardStyle()

  private var shape: ConcentricRectangle {
    cardStyle.insetShape(by: ComposerCardStyle.contentPadding)
  }

  private var info: String? {
    guard let description, !description.isEmpty else { return nil }
    return description
  }

  var body: some View {
    HStack(spacing: 0) {
      Button(action: action) {
        HStack(alignment: .center, spacing: 12) {
          indicatorView
            .frame(width: 24)
          Text(title)
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 14)
        .padding(.trailing, info == nil ? 14 : 4)
        .padding(.vertical, 12)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
      }
      .buttonStyle(QuestionOptionButtonStyle())
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      .accessibilityHint(info ?? "")

      if let info {
        infoButton(info)
      }
    }
    .background(shape.fill(fillStyle))
    .overlay(
      cardStyle.insetShape(by: ComposerCardStyle.contentPadding + Self.ringWidth / 2)
        .stroke(theme.accent.opacity(isSelected ? 0.55 : 0), lineWidth: Self.ringWidth)
        .padding(Self.ringWidth / 2)
    )
    .contentShape(shape)
    .hoverEffectDisabled()
  }

  private func infoButton(_ info: String) -> some View {
    Button {
      showsInfo = true
    } label: {
      Image(systemName: "info.circle")
        .font(.title3)
        .foregroundStyle(showsInfo ? theme.accent : Color.secondary)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.trailing, 4)
    .accessibilityLabel("About \(title)")
    .popover(isPresented: $showsInfo, arrowEdge: .bottom) {
      Text(info)
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
        .padding()
        .frame(idealWidth: 300, maxWidth: 320, alignment: .leading)
        .presentationCompactAdaptation(.popover)
    }
  }

  private var fillStyle: AnyShapeStyle {
    isSelected
      ? AnyShapeStyle(theme.accent.opacity(0.14))
      : AnyShapeStyle(HierarchicalShapeStyle.quaternary.opacity(0.6))
  }

  private var indicatorView: some View {
    Image(systemName: symbolName)
      .font(.title3)
      .foregroundStyle(isSelected ? theme.accent : Color.secondary)
      .contentTransition(.symbolEffect(.replace))
      .accessibilityHidden(true)
  }

  private var symbolName: String {
    switch indicator {
    case .single: isSelected ? "checkmark.circle.fill" : "circle"
    case .multiple: isSelected ? "checkmark.square.fill" : "square"
    }
  }
}

private struct QuestionOptionButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
      .opacity(configuration.isPressed ? 0.85 : 1)
      .animation(.snappy(duration: 0.15), value: configuration.isPressed)
  }
}
