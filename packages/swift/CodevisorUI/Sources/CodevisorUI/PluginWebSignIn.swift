import AuthenticationServices
import Foundation

@MainActor
public final class PluginWebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
  private var session: ASWebAuthenticationSession?
  private var completion: CheckedContinuation<Void, Never>?

  public func run(_ url: URL, callbackScheme: String? = nil) async {
    finish()
    await withCheckedContinuation { continuation in
      completion = continuation
      let session = ASWebAuthenticationSession(
        url: url,
        callbackURLScheme: callbackScheme,
        completionHandler: Self.completionHandler { [weak self] in self?.finish() }
      )
      session.presentationContextProvider = self
      session.prefersEphemeralWebBrowserSession = false
      self.session = session
      if !session.start() { finish() }
    }
  }

  public func cancel() {
    session?.cancel()
    finish()
  }

  nonisolated public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    MainActor.assumeIsolated { WebAuthenticationAnchor.current }
  }

  private func finish() {
    session = nil
    completion?.resume()
    completion = nil
  }

  private nonisolated static func completionHandler(
    _ done: @escaping @MainActor @Sendable () -> Void
  ) -> ASWebAuthenticationSession.CompletionHandler {
    { @Sendable _, _ in
      Task { @MainActor in done() }
    }
  }
}
