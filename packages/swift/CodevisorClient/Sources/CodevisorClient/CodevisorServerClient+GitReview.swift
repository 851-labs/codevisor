import Foundation

public enum ServerGitDiffMode: String, Codable, CaseIterable, Sendable {
  case branch
  case uncommitted
  case staged
  case unstaged
  case lastTurn
}

public struct ServerGitDiffFile: Codable, Equatable, Sendable, Identifiable {
  public enum Status: String, Codable, Sendable {
    case added, modified, deleted, renamed
  }

  public enum Omission: String, Codable, Sendable {
    case binary, tooLarge
  }

  public var id: String { path }
  public let path: String
  public let oldPath: String?
  public let status: Status
  public let fingerprint: String?
  public let oldText: String?
  public let newText: String?
  public let omitted: Omission?

  public init(
    path: String,
    oldPath: String? = nil,
    status: Status,
    fingerprint: String? = nil,
    oldText: String?,
    newText: String?,
    omitted: Omission? = nil
  ) {
    self.path = path
    self.oldPath = oldPath
    self.status = status
    self.fingerprint = fingerprint
    self.oldText = oldText
    self.newText = newText
    self.omitted = omitted
  }
}

public struct ServerGitDiff: Codable, Equatable, Sendable {
  public let mode: ServerGitDiffMode
  public let repositoryRoot: String
  public let base: String?
  public let files: [ServerGitDiffFile]
  public let truncated: Bool
  public let revision: String?
  public let unchanged: Bool?

  public init(
    mode: ServerGitDiffMode,
    repositoryRoot: String,
    base: String? = nil,
    files: [ServerGitDiffFile],
    truncated: Bool = false,
    revision: String? = nil,
    unchanged: Bool? = nil
  ) {
    self.mode = mode
    self.repositoryRoot = repositoryRoot
    self.base = base
    self.files = files
    self.truncated = truncated
    self.revision = revision
    self.unchanged = unchanged
  }
}

public struct ServerGitRefs: Codable, Equatable, Sendable {
  public struct Branch: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let remote: Bool

    public init(name: String, remote: Bool) {
      self.name = name
      self.remote = remote
    }
  }

  public let currentBranch: String?
  public let defaultBase: String?
  public let branches: [Branch]

  public init(currentBranch: String?, defaultBase: String?, branches: [Branch]) {
    self.currentBranch = currentBranch
    self.defaultBase = defaultBase
    self.branches = branches
  }
}

public struct ServerGitPullRequest: Codable, Equatable, Hashable, Sendable {
  public enum State: String, Codable, Sendable {
    case open
    case closed
    case merged
  }

  public enum Checks: String, Codable, Sendable {
    case passing
    case failing
    case pending
    case none
  }

  public let number: Int
  public let title: String
  public let state: State
  public let isDraft: Bool
  public let url: URL
  public let checks: Checks

  public init(number: Int, title: String, state: State, isDraft: Bool, url: URL, checks: Checks = .none) {
    self.number = number
    self.title = title
    self.state = state
    self.isDraft = isDraft
    self.url = url
    self.checks = checks
  }

  private enum CodingKeys: String, CodingKey {
    case number, title, state, isDraft, url, checks
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    number = try container.decode(Int.self, forKey: .number)
    title = try container.decode(String.self, forKey: .title)
    state = try container.decode(State.self, forKey: .state)
    isDraft = try container.decode(Bool.self, forKey: .isDraft)
    url = try container.decode(URL.self, forKey: .url)
    checks = try container.decodeIfPresent(Checks.self, forKey: .checks) ?? .none
  }
}

struct ServerGitPullRequestLookup: Decodable {
  let pullRequest: ServerGitPullRequest?
}

extension CodevisorServerClient {
  public func gitDiff(
    path: String, mode: ServerGitDiffMode, base: String?, revision: String?
  ) async throws -> ServerGitDiff {
    var items = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "mode", value: mode.rawValue)]
    if mode == .branch, let base, !base.isEmpty {
      items.append(URLQueryItem(name: "base", value: base))
    }
    if let revision {
      items.append(URLQueryItem(name: "revision", value: revision))
    }
    return try await get(gitRequestPath("/v1/fs/git/diff", items: items))
  }

  public func gitRefs(path: String) async throws -> ServerGitRefs {
    try await get(gitRequestPath("/v1/fs/git/refs", items: [URLQueryItem(name: "path", value: path)]))
  }

  public func gitPullRequest(path: String) async throws -> ServerGitPullRequest? {
    let lookup: ServerGitPullRequestLookup = try await get(
      gitRequestPath("/v1/fs/git/pull-request", items: [URLQueryItem(name: "path", value: path)])
    )
    return lookup.pullRequest
  }

  private func gitRequestPath(_ endpoint: String, items: [URLQueryItem]) throws -> String {
    var components = URLComponents()
    components.path = endpoint
    components.queryItems = items
    components.percentEncodedQuery = components.percentEncodedQuery?
      .replacingOccurrences(of: "+", with: "%2B")
    guard let value = components.string else { throw CodevisorServerClientError.invalidURL(endpoint) }
    return value
  }
}

extension CodevisorServerClienting {
  public func gitDiff(
    path: String, mode: ServerGitDiffMode, base: String?, revision: String?
  ) async throws -> ServerGitDiff {
    throw CodevisorServerClientError.invalidResponse
  }
  public func gitRefs(path: String) async throws -> ServerGitRefs {
    throw CodevisorServerClientError.invalidResponse
  }
  public func gitPullRequest(path: String) async throws -> ServerGitPullRequest? {
    throw CodevisorServerClientError.invalidResponse
  }
}
