import SwiftUI

struct ComposerSlimCircleButton: View {
  static let diameter: CGFloat = 36

  let systemImage: String
  var isProminent = false
  var isEnabled = true
  var isBusy = false
  let help: String
  let accessibilityLabel: String
  let action: () -> Void

  var body: some View {
    Button(action: action) { label }
      .buttonStyle(.plain)
      .disabled(!isEnabled || isBusy)
      .glassEffect(glass, in: .circle)
      .help(help)
      .accessibilityLabel(accessibilityLabel)
  }

  private var label: some View {
    Group {
      if isBusy {
        ProgressView().controlSize(.small)
      } else {
        Image(systemName: systemImage)
          .font(.system(size: 15, weight: .semibold))
      }
    }
    .foregroundStyle(foreground)
    .frame(width: Self.diameter, height: Self.diameter)
    .contentShape(.circle)
  }

  private var glass: Glass {
    isProminent ? .regular.tint(.accentColor).interactive() : .regular.interactive()
  }

  private var foreground: AnyShapeStyle {
    if isProminent { return AnyShapeStyle(.white) }
    return isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)
  }
}
