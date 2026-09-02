import AuthenticationServices
import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import UserNotifications
import os

/// Owns the ASWebAuthenticationSession for the browser sign-in and anchors it
/// to the key window. Sign-in state is shared with Safari on purpose
/// (`prefersEphemeralWebBrowserSession = false`) so a returning user doesn't
/// re-enter GitHub credentials. Internal (not private) so onboarding's
/// sign-in affordance can reuse it.
@MainActor
final class CloudSignInCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
  private var session: ASWebAuthenticationSession?

  /// The callback scheme for the browser handoff. iOS registers both
  /// `codevisor` and `codevisor-dev` (a dev build can handle links minted
  /// for production installs); prefer the scheme matching this build so the
  /// handoff round-trips into the right place.
  static var callbackScheme: String {
    let schemes =
      (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])?
      .flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] } ?? []
    let preferred = CodevisorAppVariant.isDevelopment ? "codevisor-dev" : "codevisor"
    if schemes.contains(preferred) { return preferred }
    return schemes.first { $0.hasPrefix("codevisor") } ?? preferred
  }

  /// Cancellation (the user closed the sheet) completes with nil.
  func start(
    url: URL,
    callbackScheme: String,
    completion: @escaping @MainActor (URL?) -> Void
  ) {
    session?.cancel()
    let session = ASWebAuthenticationSession(
      url: url,
      callbackURLScheme: callbackScheme
    ) { callbackURL, error in
      Task { @MainActor in
        if let error {
          let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
          if !cancelled {
            Log.cloud.error("Cloud sign-in session failed: \(String(describing: error), privacy: .public)")
          }
          completion(nil)
          return
        }
        completion(callbackURL)
      }
    }
    session.prefersEphemeralWebBrowserSession = false
    session.presentationContextProvider = self
    self.session = session
    session.start()
  }

  nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    // This must return synchronously and is requested on the main thread;
    // the `main.sync` fallback only guards against a stray off-main
    // request trapping `MainActor.assumeIsolated`.
    let anchor: @MainActor () -> ASPresentationAnchor = {
      UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    if Thread.isMainThread {
      return MainActor.assumeIsolated(anchor)
    }
    return DispatchQueue.main.sync {
      MainActor.assumeIsolated(anchor)
    }
  }
}
