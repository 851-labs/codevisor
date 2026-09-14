import SwiftUI

enum CloudSignInButtonMetrics {
  static let height: CGFloat = 44
  static let cornerRadius: CGFloat = 8
  static let fontSize: CGFloat = 16
}

/// Matches the native Apple button for every Cloud sign-in option.
public struct CloudSignInProviderButton: View {
  public enum Icon {
    case asset(String)
    case system(String)
  }

  private let title: String
  private let icon: Icon
  private let action: () -> Void

  public init(title: String, icon: Icon, action: @escaping () -> Void) {
    self.title = title
    self.icon = icon
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        iconView
          .frame(width: CloudSignInButtonMetrics.fontSize, height: CloudSignInButtonMetrics.fontSize)
          .accessibilityHidden(true)
        Text(title)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
      }
    }
    .buttonStyle(CloudSignInButtonStyle())
    .accessibilityLabel(title)
  }

  @ViewBuilder
  private var iconView: some View {
    switch icon {
    case let .asset(name):
      Image(name)
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
    case let .system(name):
      Image(systemName: name)
        .font(.system(size: CloudSignInButtonMetrics.fontSize, weight: .medium))
    }
  }
}

private struct CloudSignInButtonStyle: ButtonStyle {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    let foreground: Color = colorScheme == .dark ? .black : .white
    let background: Color = colorScheme == .dark ? .white : .black
    configuration.label
      .font(.system(size: CloudSignInButtonMetrics.fontSize, weight: .medium))
      .foregroundStyle(foreground)
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity)
      .frame(height: CloudSignInButtonMetrics.height)
      .background(
        background.opacity(configuration.isPressed ? 0.82 : 1),
        in: RoundedRectangle(cornerRadius: CloudSignInButtonMetrics.cornerRadius)
      )
      .contentShape(RoundedRectangle(cornerRadius: CloudSignInButtonMetrics.cornerRadius))
      .opacity(isEnabled ? 1 : 0.5)
  }
}
