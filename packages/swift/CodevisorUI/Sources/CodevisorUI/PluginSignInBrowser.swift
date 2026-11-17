import CodevisorCore
import Foundation

@MainActor
public final class PluginSignInBrowser {
  public let ticket: String?

  private let client: any CodevisorServerClienting
  private let presenter: any WebSignInPresenting
  private var opened: Task<URL?, Never>?

  public init(client: any CodevisorServerClienting, pluginName: String?, presenter: any WebSignInPresenting) {
    self.client = client
    self.presenter = presenter
    let handoff = client.signInHandoff(pluginName: pluginName)
    ticket = handoff?.ticket
    if let handoff {
      opened = Task { await presenter.run(handoff.url) }
    }
  }

  public func finish(at authorizationUrl: String) async -> URL? {
    if let opened { return await opened.value }
    guard let url = URL(string: authorizationUrl) else { return nil }
    return await presenter.run(url)
  }

  public func close() {
    presenter.cancel()
  }

  public func abandon() async {
    close()
    guard let ticket else { return }
    try? await client.abandonSignIn(ticket: ticket)
  }
}
