import CodevisorCore
import Foundation
import Observation

/// One row of a source control list: a changed path in one of its groups.
/// A file changed both in the index and after shows in both groups.
public struct SourceControlChange: Identifiable, Equatable, Sendable {
  public enum Group: String, Sendable {
    /// Conflicts to resolve, ahead of everything else.
    case merge
    /// In the index: what a commit would take.
    case staged
    /// In the working tree only, untracked files included.
    case changes
  }

  public let group: Group
  /// Repository-relative.
  public let path: String
  /// Staged renames only: unstaging one has to take back both paths.
  public let oldPath: String?
  public let code: ServerGitChangeCode

  public var id: String { "\(group.rawValue):\(path)" }
  public var name: String { (path as NSString).lastPathComponent }
  /// The parent folder, repository-relative; empty at the top level.
  public var directory: String { (path as NSString).deletingLastPathComponent }
  public var isStaged: Bool { group == .staged }
}

/// A repository's changed files, grouped the way an editor's source control
/// view groups them, and the staging changes made from that view.
@MainActor @Observable
public final class SourceControlModel {
  enum Change {
    case stage([String]?)
    case unstage([String]?)
    case discard([String])
  }

  /// Any folder inside the repository: the workspace's root.
  public let root: String
  public var selection: String?
  public private(set) var status: ServerGitStatus?
  public private(set) var isNotRepository = false
  /// The last refresh or change that failed, until one succeeds.
  public private(set) var error: String?
  public private(set) var isChanging = false
  @ObservationIgnored private let read: (String) async throws -> ServerGitStatus
  @ObservationIgnored private let change: (String, Change) async throws -> ServerGitStatus

  public convenience init(root: String, client: any CodevisorServerClienting) {
    self.init(root: root) { path in
      try await client.gitStatus(path: path)
    } change: { path, change in
      switch change {
      case let .stage(files): try await client.gitStage(path: path, files: files)
      case let .unstage(files): try await client.gitUnstage(path: path, files: files)
      case let .discard(files): try await client.gitDiscard(path: path, files: files)
      }
    }
  }

  init(
    root: String, read: @escaping (String) async throws -> ServerGitStatus,
    change: @escaping (String, Change) async throws -> ServerGitStatus
  ) {
    self.root = root
    self.read = read
    self.change = change
  }

  public var hasLoaded: Bool { status != nil || isNotRepository }

  public var merge: [SourceControlChange] { changes(in: .merge) }
  public var staged: [SourceControlChange] { changes(in: .staged) }
  public var changes: [SourceControlChange] { changes(in: .changes) }

  /// Every changed path once, for the tab's badge.
  public var count: Int { status?.entries.count ?? 0 }

  public func change(id: String) -> SourceControlChange? {
    (merge + staged + changes).first { $0.id == id }
  }

  /// The file on this machine, for opening it or copying its path.
  public func absolutePath(_ change: SourceControlChange) -> String {
    ((status?.repositoryRoot ?? root) as NSString).appendingPathComponent(change.path)
  }

  private func changes(in group: SourceControlChange.Group) -> [SourceControlChange] {
    (status?.entries ?? [])
      .compactMap { entry -> SourceControlChange? in
        let code: ServerGitChangeCode? =
          switch group {
          case .merge: entry.unstaged == .conflicted ? .conflicted : nil
          case .staged: entry.staged
          case .changes: entry.unstaged == .conflicted ? nil : entry.unstaged
          }
        return code.map {
          SourceControlChange(group: group, path: entry.path, oldPath: entry.oldPath, code: $0)
        }
      }
      .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
  }

  public func refresh() async {
    do {
      apply(try await read(root))
    } catch {
      fail(error)
    }
  }

  public func stage(_ changes: [SourceControlChange]) async {
    await perform(.stage(changes.map(\.path)))
  }

  public func stageAll() async { await perform(.stage(nil)) }

  public func unstage(_ changes: [SourceControlChange]) async {
    await perform(.unstage(changes.flatMap { [$0.path] + ($0.oldPath.map { [$0] } ?? []) }))
  }

  public func unstageAll() async { await perform(.unstage(nil)) }

  /// Throws away unstaged changes; untracked files are deleted.
  public func discard(_ changes: [SourceControlChange]) async {
    guard !changes.isEmpty else { return }
    await perform(.discard(changes.map(\.path)))
  }

  private func perform(_ request: Change) async {
    isChanging = true
    defer { isChanging = false }
    do {
      apply(try await change(root, request))
    } catch {
      fail(error)
    }
  }

  private func apply(_ next: ServerGitStatus) {
    if status != next { status = next }
    isNotRepository = false
    error = nil
  }

  private func fail(_ error: any Error) {
    guard !isTaskCancellation(error) else { return }
    if serverErrorCode(error) == "not_git_repository" {
      isNotRepository = true
      status = nil
      self.error = nil
    } else {
      self.error = serverErrorMessage(error)
    }
  }
}
