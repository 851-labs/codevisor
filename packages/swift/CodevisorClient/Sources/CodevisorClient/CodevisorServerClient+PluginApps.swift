import Foundation

extension CodevisorServerClient {
  private static let viewIdAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

  public func issuePluginAppViewToken(viewId: String) async throws -> ServerPluginPaneTokenResponse {
    let segment = viewId.addingPercentEncoding(withAllowedCharacters: Self.viewIdAllowed) ?? viewId
    return try await send("/v1/plugins/apps/\(segment)/token", method: "POST", body: Optional<EmptyBody>.none)
  }
}
