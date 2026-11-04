import CodevisorTestSupport
import Foundation

@testable import CodevisorUI

@MainActor
final class FakeWebSignIn: WebSignInPresenting {
  let presented = TestSignal()
  private(set) var urls: [URL] = []
  private(set) var closeCount = 0
  private var open: CheckedContinuation<URL?, Never>?

  var isOpen: Bool { open != nil }

  @discardableResult
  func run(_ url: URL) async -> URL? {
    urls.append(url)
    return await withCheckedContinuation { continuation in
      open = continuation
      presented.signal()
    }
  }

  func cancel() {
    closeCount += 1
    open?.resume(returning: nil)
    open = nil
  }

  func complete(with callback: URL) {
    open?.resume(returning: callback)
    open = nil
  }
}
