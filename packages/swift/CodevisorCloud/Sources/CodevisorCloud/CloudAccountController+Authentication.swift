import Foundation

/// Captures the account and server that authorized an authentication attempt.
/// A delayed sheet must never restore a signed-out account or link a new one.
public struct CloudAuthenticationContext: Sendable {
  let server: URL
  let token: String?
  let revision: UInt64
  let link: Bool
}

extension CloudAccountController {
  public func authenticationContext(link: Bool) throws -> CloudAuthenticationContext {
    if link && (!state.isSignedIn || storedToken == nil) {
      throw CloudAccountClientError.missingToken
    }
    lastError = nil
    return CloudAuthenticationContext(
      server: serverURL, token: storedToken, revision: authenticationRevision, link: link)
  }

  public func isCurrent(_ context: CloudAuthenticationContext) -> Bool {
    context.server == serverURL && context.token == storedToken && context.revision == authenticationRevision
  }

  public func startNativeApple(_ context: CloudAuthenticationContext) async throws -> CloudAppleChallenge {
    guard isCurrent(context) else { throw CancellationError() }
    let challenge = try await client.startAppleSignIn(link: context.link, token: context.link ? context.token : nil)
    guard isCurrent(context), !Task.isCancelled else { throw CancellationError() }
    return challenge
  }

  public func completeNativeApple(_ credential: CloudAppleCredential, context: CloudAuthenticationContext) async throws
  {
    guard isCurrent(context), !Task.isCancelled else { throw CancellationError() }
    let token = try await client.completeAppleSignIn(credential, token: context.link ? context.token : nil)
    try await completeAuthentication(token: token, context: context)
  }

  public func completeBrowserAuthentication(ott: String, context: CloudAuthenticationContext) async throws {
    guard isCurrent(context), !Task.isCancelled else { throw CancellationError() }
    let token = try await client.verifyOneTimeToken(ott)
    try await completeAuthentication(token: token, context: context)
  }

  func completeAuthentication(token: String, context: CloudAuthenticationContext) async throws {
    guard isCurrent(context), !Task.isCancelled else { throw CancellationError() }
    if context.link {
      guard token == context.token else { throw CloudAccountClientError.invalidResponse }
      await refreshLinkedProviders()
    } else {
      await adoptSession { token }
    }
  }

  public func refreshLinkedProviders() async {
    guard state.isSignedIn, let token = storedToken else { return }
    let server = serverURL
    do {
      let providers = try await client.linkedProviders(token: token)
      guard storedToken == token, serverURL == server else { return }
      linkedProviders = providers
      lastError = nil
    } catch {
      guard storedToken == token, serverURL == server else { return }
      lastError = error.localizedDescription
    }
  }
}
