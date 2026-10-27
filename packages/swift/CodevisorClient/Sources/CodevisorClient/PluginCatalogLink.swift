import Foundation

public enum PluginCatalogLink {
  private static let hosts: Set<String> = ["codevisor.dev", "www.codevisor.dev"]
  private static let maxIdLength = 200

  public static func catalogId(from url: URL) -> String? {
    guard isCodevisorPage(url) else { return nil }

    let parts = url.path(percentEncoded: true).split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count == 2, parts[0] == "plugins" else { return nil }
    guard let id = String(parts[1]).removingPercentEncoding, isValid(id) else { return nil }
    return id
  }

  private static func isCodevisorPage(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https" && hosts.contains(url.host()?.lowercased() ?? "")
      && url.user == nil && url.password == nil && url.port == nil
  }

  private static func isValid(_ id: String) -> Bool {
    guard !id.isEmpty, id.count <= maxIdLength, !id.contains("..") else { return false }
    return id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._/".contains($0)) }
  }
}
