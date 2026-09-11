import AuthenticationServices
import SwiftUI

/// Apple's standard button starts native authorization on iOS and browser
/// authorization on macOS, including Developer ID distributions.
public struct CloudAppleSignInButton: View {
  @Environment(\.colorScheme) private var colorScheme
  private let action: () -> Void

  public init(action: @escaping () -> Void) {
    self.action = action
  }

  public var body: some View {
    AppleAuthorizationButton(style: colorScheme == .dark ? .white : .black, action: action)
      .id(colorScheme)
      .frame(maxWidth: .infinity)
      .frame(height: CloudSignInButtonMetrics.height)
  }
}

@MainActor
private struct AppleAuthorizationButton {
  let style: ASAuthorizationAppleIDButton.Style
  let action: () -> Void

  @MainActor
  final class Coordinator: NSObject {
    var action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func signIn() { action() }
  }

  func makeCoordinator() -> Coordinator { Coordinator(action: action) }
}

#if os(iOS)
  extension AppleAuthorizationButton: UIViewRepresentable {
    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
      let button = ASAuthorizationAppleIDButton(type: .signIn, style: style)
      button.cornerRadius = CloudSignInButtonMetrics.cornerRadius
      button.addTarget(context.coordinator, action: #selector(Coordinator.signIn), for: .touchUpInside)
      return button
    }

    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
      context.coordinator.action = action
      button.isEnabled = context.environment.isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ASAuthorizationAppleIDButton, context: Context) -> CGSize? {
      CGSize(width: proposal.width ?? 320, height: CloudSignInButtonMetrics.height)
    }
  }
#elseif os(macOS)
  extension AppleAuthorizationButton: NSViewRepresentable {
    func makeNSView(context: Context) -> ASAuthorizationAppleIDButton {
      let button = ASAuthorizationAppleIDButton(type: .signIn, style: style)
      button.cornerRadius = CloudSignInButtonMetrics.cornerRadius
      button.target = context.coordinator
      button.action = #selector(Coordinator.signIn)
      return button
    }

    func updateNSView(_ button: ASAuthorizationAppleIDButton, context: Context) {
      context.coordinator.action = action
      button.isEnabled = context.environment.isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ASAuthorizationAppleIDButton, context: Context) -> CGSize? {
      CGSize(width: proposal.width ?? 320, height: CloudSignInButtonMetrics.height)
    }
  }
#endif
