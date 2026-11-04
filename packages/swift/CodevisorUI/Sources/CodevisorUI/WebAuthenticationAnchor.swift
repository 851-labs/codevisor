#if os(iOS)
  import AuthenticationServices
  import UIKit

  @MainActor
  enum WebAuthenticationAnchor {
    static var current: ASPresentationAnchor {
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      if let keyWindow = scenes.flatMap(\.windows).first(where: \.isKeyWindow) { return keyWindow }
      guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
        preconditionFailure("Sign-in was requested with no connected window scene to present from")
      }
      return scene.windows.first ?? UIWindow(windowScene: scene)
    }
  }
#endif
