import CodevisorClient
import Foundation

@MainActor
final class ChromiumFirstPage {
  private static let homePage = "https://www.google.com/"
  var newTabURL: String?
  var followsUser = false
  var opening: String?
  private var saved: Task<BrowserNavigation?, Error>?

  var knowsAddress: Bool { saved == nil }

  func begin(paneId: UUID, client: any CodevisorServerClienting) {
    guard newTabURL == nil, !followsUser else { return saved = nil }
    saved = Task { try await client.browserNavigation(paneId: paneId) }
  }

  func immediateAddress(current url: URL?) -> String {
    newTabURL ?? url?.absoluteString ?? Self.homePage
  }

  func address(current url: URL?) async -> String {
    let navigation = try? await saved?.value
    saved = nil
    guard newTabURL == nil, !followsUser, let navigation else { return immediateAddress(current: url) }
    return navigation.url
  }
}
