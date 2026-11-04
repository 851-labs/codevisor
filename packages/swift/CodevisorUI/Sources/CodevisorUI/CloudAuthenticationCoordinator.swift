import AuthenticationServices
import CodevisorCore
import Foundation

@MainActor
public final class CloudAuthenticationCoordinator: NSObject {
  private let browser: BrowserSignIn
  private var active = false
  #if os(iOS)
    private var appleController: ASAuthorizationController?
    private var appleChallenge: CloudAppleChallenge?
    private var appleCompletion: CheckedContinuation<CloudAppleCredential, any Error>?
  #endif

  public init(browser: BrowserSignIn = .shared) {
    self.browser = browser
  }

  public func signIn(provider: CloudSignInProvider, cloud: CloudAccountController, link: Bool = false) async {
    guard !active else { return }
    active = true
    defer { active = false }
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
      guard let url = await signInPage(provider: provider, cloud: cloud, link: link), cloud.isCurrent(context) else {
        return
      }
      guard let callback = await browser.run(url) else { return }
      guard let handoff = CloudAuthDeeplink.parse(callback) else {
        throw CloudAccountClientError.authenticationFailed(Self.incompleteMessage(link: link))
      }
      try await cloud.completeBrowserAuthentication(ott: handoff.ott, context: context)
    } catch is CancellationError {
      return
    } catch {
      guard cloud.isCurrent(context) else { return }
      cloud.lastError = error.localizedDescription
    }
  }

  private func signInPage(provider: CloudSignInProvider, cloud: CloudAccountController, link: Bool) async -> URL? {
    let scheme = CodevisorDeeplinkScheme.current
    guard link else { return cloud.signInURL(scheme: scheme, provider: provider) }
    return await cloud.connectAccountURL(provider: provider, scheme: scheme)
  }

  private static func incompleteMessage(link: Bool) -> String {
    guard link else {
      return
        "Sign-in didn't complete. If you already have an account, sign in with that method and connect this provider in Account settings."
    }
    return "Couldn't connect this account. It may already belong to another Codevisor account. Please try again."
  }
}

#if os(iOS)
  extension CloudAuthenticationCoordinator: ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding
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
      WebAuthenticationAnchor.current
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
