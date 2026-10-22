import Foundation

public enum GitHostProvider: String, Sendable, CaseIterable, Identifiable {
  case github, gitlab, bitbucket

  public var id: String { rawValue }

  public init?(host: String) {
    let name = host.lowercased()
    if name == "github.com" {
      self = .github
    } else if name == "gitlab.com" || name.hasPrefix("gitlab.") {
      self = .gitlab
    } else if name == "bitbucket.org" {
      self = .bitbucket
    } else {
      return nil
    }
  }

  public var displayName: String {
    switch self {
    case .github: "GitHub"
    case .gitlab: "GitLab"
    case .bitbucket: "Bitbucket"
    }
  }

  public var cliName: String { "\(displayName) CLI" }

  public var defaultHost: String {
    switch self {
    case .github: "github.com"
    case .gitlab: "gitlab.com"
    case .bitbucket: "bitbucket.org"
    }
  }

  public var supportsSignIn: Bool { self != .bitbucket }

  public func newRepositoryURL(named name: String) -> URL? {
    switch self {
    case .github:
      var components = URLComponents(string: "https://github.com/new")
      components?.queryItems = [URLQueryItem(name: "name", value: name)]
      return components?.url
    case .gitlab: return URL(string: "https://gitlab.com/projects/new")
    case .bitbucket: return URL(string: "https://bitbucket.org/repo/create")
    }
  }
}

public enum GitRemoteURL {
  public static func repositoryName(of rawURL: String) -> String {
    var value = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if let scheme = value.range(of: "://") { value = String(value[scheme.upperBound...]) }
    if let host = host(of: rawURL), let range = value.range(of: host, options: .caseInsensitive) {
      value = String(value[range.upperBound...])
    }
    value = value.trimmingCharacters(in: CharacterSet(charactersIn: ":/"))
    if value.hasSuffix(".git") { value.removeLast(4) }
    return value.isEmpty ? rawURL : value
  }

  public static func isValid(_ rawURL: String) -> Bool {
    let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    return !url.contains(where: \.isWhitespace) && host(of: url) != nil && repositoryName(of: url).contains("/")
  }

  public static func host(of rawURL: String) -> String? {
    let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if url.contains("://") {
      guard let host = URLComponents(string: url)?.host, !host.isEmpty else { return nil }
      return host.lowercased()
    }
    let withoutUser = url.split(separator: "@", maxSplits: 1).last.map(String.init) ?? url
    guard let colon = withoutUser.firstIndex(of: ":") else { return nil }
    let host = withoutUser[..<colon]
    return host.isEmpty || host.contains("/") ? nil : host.lowercased()
  }
}
