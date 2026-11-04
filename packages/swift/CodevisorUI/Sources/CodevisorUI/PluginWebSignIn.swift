import Foundation
import OSLog

let pluginSignInLog = Logger(subsystem: "dev.codevisor.plugins", category: "sign-in")

@MainActor
public final class PluginWebSignIn: WebSignInPresenting {
  private let browser: BrowserSignIn
  private var attempt: UUID?

  public init(browser: BrowserSignIn = .shared) {
    self.browser = browser
  }

  @discardableResult
  public func run(_ url: URL) async -> URL? {
    let id = UUID()
    attempt = id
    let callback = await browser.run(url, id: id)
    if attempt == id { attempt = nil }
    return callback
  }

  public func cancel() {
    guard let attempt else { return }
    browser.cancel(attempt)
  }
}
