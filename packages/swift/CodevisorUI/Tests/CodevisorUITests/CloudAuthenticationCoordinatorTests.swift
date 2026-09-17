import AuthenticationServices
import Foundation
import Testing
@testable import CodevisorUI

@MainActor
@Suite("Cloud authentication callbacks")
struct CloudAuthenticationCoordinatorTests {
  @Test(arguments: [false, true])
  func successReturnsToMainActor(background: Bool) async throws {
    let expected = try #require(URL(string: "codevisor://auth?ott=test"))
    let (callback, error) = await deliver(callback: expected, error: nil, background: background)
    #expect(callback == expected)
    #expect(error == nil)
  }

  @Test(arguments: [false, true])
  func cancellationAndErrorsReturnToMainActor(background: Bool) async {
    for code in [ASWebAuthenticationSessionError.Code.canceledLogin, .presentationContextInvalid] {
      let expected = ASWebAuthenticationSessionError(code)
      let (callback, error) = await deliver(callback: nil, error: expected, background: background)
      #expect(callback == nil)
      #expect((error as? ASWebAuthenticationSessionError)?.code == code)
    }
  }

  @Test func emptyResultReturnsToMainActor() async {
    let (callback, error) = await deliver(callback: nil, error: nil, background: true)
    #expect(callback == nil)
    #expect(error == nil)
  }

  private func deliver(
    callback: URL?, error: (any Error)?, background: Bool
  ) async -> (URL?, (any Error)?) {
    await withCheckedContinuation { continuation in
      let completion = CloudAuthenticationCoordinator.webAuthenticationCompletion { callback, error in
        MainActor.preconditionIsolated()
        continuation.resume(returning: (callback, error))
      }
      let legacyCallback = LegacyCallback(completion: completion)
      let queue = background ? DispatchQueue.global() : DispatchQueue.main
      queue.async {
        dispatchPrecondition(condition: background ? .notOnQueue(.main) : .onQueue(.main))
        legacyCallback.completion(callback, error)
      }
    }
  }
}

// The SDK callback type has no Sendable annotation. Deliberately cross that
// boundary as AuthenticationServices does, so an inferred actor check would trap.
private struct LegacyCallback: @unchecked Sendable {
  let completion: ASWebAuthenticationSession.CompletionHandler
}
