@MainActor
final class ChromiumPageReadiness {
  private var waiters: [CheckedContinuation<CVChromiumView, Error>] = []
  private(set) var failure: Error?

  func wait() async throws -> CVChromiumView {
    try await withCheckedThrowingContinuation { waiters.append($0) }
  }

  func complete(_ result: Result<CVChromiumView, Error>) {
    if case .failure(let error) = result { failure = error }
    let pending = waiters
    waiters = []
    for waiter in pending { waiter.resume(with: result) }
  }

  func forgetFailure() { failure = nil }
}
