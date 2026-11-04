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

  public func run(_ url: URL) async {
    let id = UUID()
    attempt = id
    _ = await browser.run(url, id: id)
    if attempt == id { attempt = nil }
  }

  public func cancel() {
    guard let attempt else { return }
    browser.cancel(attempt)
  }
}
