import AuthenticationServices
import CodevisorCore
import Foundation

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

/// Owns provider authentication sheets and returns all account UI to the app.
@MainActor
public final class CloudAuthenticationCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
  private var webSession: ASWebAuthenticationSession?
  private var webRequestID: UUID?
  private var webCompletion: CheckedContinuation<URL, any Error>?
  private var active = false
  #if os(iOS)
    private var appleController: ASAuthorizationController?
    private var appleChallenge: CloudAppleChallenge?
    private var appleCompletion: CheckedContinuation<CloudAppleCredential, any Error>?
  #endif

  public static var callbackScheme: String {
    let schemes =
      (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])?
      .flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] } ?? []
    let preferred = CodevisorAppVariant.isDevelopment ? "codevisor-dev" : "codevisor"
    if schemes.contains(preferred) { return preferred }
    return schemes.first { $0.hasPrefix("codevisor") } ?? preferred
  }

  public func signIn(provider: CloudSignInProvider, cloud: CloudAccountController, link: Bool = false) async {
    guard !active else { return }
    active = true
    defer { active = false; webSession = nil }
    guard let context = try? cloud.authenticationContext(link: link) else { return }
    do {
      #if os(iOS)
        if provider == .apple {
          let challenge = try await cloud.startNativeApple(context)
          let credential = try await authorizeApple(challenge)
          try await cloud.completeNativeApple(credential, context: context)
          return
        }
      #endif
      let url: URL
      if link {
        guard let connectURL = await cloud.connectAccountURL(provider: provider, scheme: Self.callbackScheme),
          cloud.isCurrent(context)
        else { return }
        url = connectURL
      } else {
        url = cloud.signInURL(scheme: Self.callbackScheme, provider: provider)
      }
      let callback = try await authorizeWeb(url)
      guard let handoff = CloudAuthDeeplink.parse(callback) else {
        throw CloudAccountClientError.authenticationFailed(
          link
            ? "Couldn't connect this account. It may already belong to another Codevisor account. Please try again."
            : "Sign-in didn't complete. If you already have an account, sign in with that method and connect this provider in Account settings."
        )
      }
      try await cloud.completeBrowserAuthentication(ott: handoff.ott, context: context)
    } catch is CancellationError {
      return
    } catch {
      guard cloud.isCurrent(context) else { return }
      cloud.lastError = error.localizedDescription
    }
  }

  private func authorizeWeb(_ url: URL) async throws -> URL {
    let requestID = UUID()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { completion in
        webRequestID = requestID
        webCompletion = completion
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.callbackScheme) {
          [weak self] callback, error in
          Task { @MainActor in self?.finishWeb(requestID: requestID, callback: callback, error: error) }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        webSession = session
        if !session.start() {
          finishWeb(requestID: requestID, callback: nil, error: nil)
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard self?.webRequestID == requestID else { return }
        self?.webSession?.cancel()
      }
    }
  }

  private func finishWeb(requestID: UUID, callback: URL?, error: (any Error)?) {
    guard webRequestID == requestID, let completion = webCompletion else { return }
    webRequestID = nil
    webCompletion = nil
    if let callback {
      completion.resume(returning: callback)
    } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
      completion.resume(throwing: CancellationError())
    } else {
      completion.resume(
        throwing: CloudAccountClientError.authenticationFailed("Couldn't open sign-in. Please try again."))
    }
  }

  nonisolated public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    MainActor.assumeIsolated { presentationWindow }
  }

  private var presentationWindow: ASPresentationAnchor {
    #if os(iOS)
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    #else
      NSApp.keyWindow ?? NSApp.mainWindow ?? ASPresentationAnchor()
    #endif
  }
}

#if os(iOS)
  extension CloudAuthenticationCoordinator: @preconcurrency ASAuthorizationControllerDelegate,
    @preconcurrency ASAuthorizationControllerPresentationContextProviding
  {
    private func authorizeApple(_ challenge: CloudAppleChallenge) async throws -> CloudAppleCredential {
      defer { appleController = nil; appleChallenge = nil; appleCompletion = nil }
      return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { completion in
          let request = ASAuthorizationAppleIDProvider().createRequest()
          request.requestedScopes = [.fullName, .email]
          request.state = challenge.id
          request.nonce = challenge.nonce
          let controller = ASAuthorizationController(authorizationRequests: [request])
          controller.delegate = self
          controller.presentationContextProvider = self
          appleChallenge = challenge
          appleCompletion = completion
          appleController = controller
          controller.performRequests()
        }
      } onCancel: {
        Task { @MainActor [weak self] in
          guard self?.appleChallenge?.id == challenge.id else { return }
          self?.appleController?.cancel()
        }
      }
    }

    public func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
      presentationWindow
    }

    public func authorizationController(
      controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization
    ) {
      guard controller === appleController, let completion = appleCompletion else { return }
      appleCompletion = nil
      guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
        let challenge = appleChallenge, credential.state == challenge.id,
        let data = credential.authorizationCode,
        let code = String(data: data, encoding: .utf8), !code.isEmpty
      else {
        completion.resume(throwing: CloudAccountClientError.invalidResponse)
        return
      }
      completion.resume(
        returning: CloudAppleCredential(
          challengeId: challenge.id, authorizationCode: code,
          firstName: credential.fullName?.givenName, lastName: credential.fullName?.familyName))
    }

    public func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
      guard controller === appleController, let completion = appleCompletion else { return }
      appleCompletion = nil
      let failure: any Error =
        (error as? ASAuthorizationError)?.code == .canceled
        ? CancellationError()
        : CloudAccountClientError.authenticationFailed(
          "Apple sign-in couldn't finish. Check that you're signed in to your Apple Account in Settings, then try again."
        )
      completion.resume(throwing: failure)
    }
  }
#endif
