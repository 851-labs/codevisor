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

  func refreshIfUnknown(for account: CloudAccountController) {
    guard advertised == nil else { return }
    let client = account.client
    Task { [weak self] in
      guard let providers = try? await client.discover().authProviders else { return }
      guard let self, self.advertised == nil else { return }
      self.advertised = providers
    }
  }
}
