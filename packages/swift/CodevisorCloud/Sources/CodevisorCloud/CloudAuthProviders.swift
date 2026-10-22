import CodevisorClient
import Foundation
import Observation

@MainActor
@Observable
final class CloudAuthProviders {
  private(set) var advertised: [String]?

  var offersGitHub: Bool { advertised?.contains("github") ?? true }
  var offersApple: Bool { advertised?.contains("apple") == true }
  var offersDevelopmentAccount: Bool { advertised?.contains("dev") == true }

  func refresh(using client: any CloudAccountClienting) async {
    do {
      advertised = try await client.discover().authProviders
    } catch {
      Log.cloud.error("Cloud discovery failed: \(String(describing: error), privacy: .public)")
    }
  }

  func adopt(_ providers: [String]?) {
    advertised = providers
  }

  func refreshIfUnknown(for account: CloudAccountController) {
    guard advertised == nil else { return }
    let server = account.serverURL
    let client = account.clientFactory(server)
    Task { [weak self, weak account] in
      guard let providers = try? await client.discover().authProviders else { return }
      guard let self, let account, account.serverURL == server, self.advertised == nil else { return }
      self.advertised = providers
    }
  }
}
