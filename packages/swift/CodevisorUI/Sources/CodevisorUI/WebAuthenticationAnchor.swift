import AuthenticationServices

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

@MainActor
enum WebAuthenticationAnchor {
  static var current: ASPresentationAnchor {
    #if os(iOS)
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      if let keyWindow = scenes.flatMap(\.windows).first(where: \.isKeyWindow) { return keyWindow }
      guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
        preconditionFailure("Sign-in was requested with no connected window scene to present from")
      }
      return scene.windows.first ?? UIWindow(windowScene: scene)
    #else
      NSApp.keyWindow ?? NSApp.mainWindow ?? ASPresentationAnchor()
    #endif
  }
}
