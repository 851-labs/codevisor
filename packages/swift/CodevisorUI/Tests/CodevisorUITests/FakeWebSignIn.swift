import CodevisorTestSupport
import Foundation

@testable import CodevisorUI

@MainActor
final class FakeWebSignIn: WebSignInPresenting {
  let presented = TestSignal()
  private(set) var urls: [URL] = []
  private(set) var closeCount = 0
  private var open: CheckedContinuation<Void, Never>?

  var isOpen: Bool { open != nil }

  func run(_ url: URL, callbackScheme: String?) async {
    urls.append(url)
    await withCheckedContinuation { continuation in
      open = continuation
      presented.signal()
    }
  }

  func cancel() {
    closeCount += 1
    open?.resume()
    open = nil
  }
}
