import Foundation

/// What a review compares the working state against. Raw values are the
/// server's `mode` query values.
public enum ServerGitDiffMode: String, Codable, CaseIterable, Sendable {
  /// Everything on this branch since it left the base branch, including
  /// uncommitted and untracked work — what a pull request would show.
  case branch
  /// HEAD against the working tree, untracked files included.
  case uncommitted
  /// HEAD against the index.
  case staged
  /// The index against the working tree, untracked files included.
  case unstaged
  /// The working tree when the latest agent turn started against now.
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
  /// Repository-relative. Deletions carry the removed path.
  public let path: String
  /// Renames only.
  public let oldPath: String?
  public let status: Status
  /// Identifies exactly this change (both sides' blob ids); per-file review
  /// state keys on it so it lapses when the file changes. Nil from servers
  /// that predate it.
  public let fingerprint: String?
  /// Nil when the side doesn't exist or the content was omitted.
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
  /// Branch mode: the base ref the server actually compared against.
  public let base: String?
  public let files: [ServerGitDiffFile]
  public let truncated: Bool
  /// Identifies exactly what was compared; send it back to poll cheaply.
  /// Nil from servers that predate polling.
  public let revision: String?
  /// The request's revision is still current: `files` is empty, not resent.
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

  /// Nil when HEAD is detached.
  public let currentBranch: String?
  /// The repository's conventional base (`origin/main`, …), if one resolves.
  public let defaultBase: String?
  public let branches: [Branch]

  public init(currentBranch: String?, defaultBase: String?, branches: [Branch]) {
    self.currentBranch = currentBranch
    self.defaultBase = defaultBase
    self.branches = branches
  }
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

  private func gitRequestPath(_ endpoint: String, items: [URLQueryItem]) throws -> String {
    var components = URLComponents()
    components.path = endpoint
    components.queryItems = items
    // URLComponents leaves "+" literal, which URLSearchParams reads as a
    // space; branch names and paths may legitimately contain one.
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
}
