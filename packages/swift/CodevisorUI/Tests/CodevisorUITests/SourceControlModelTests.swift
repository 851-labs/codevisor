import CodevisorClient
import Foundation
import Testing

@testable import CodevisorUI

@MainActor struct SourceControlModelTests {
  /// An in-memory repository: its status, and the changes asked of it.
  @MainActor final class Repository {
    var status: ServerGitStatus
    var requests: [String] = []
    init(_ entries: [ServerGitStatusEntry]) {
      status = ServerGitStatus(repositoryRoot: "/repo", branch: "main", entries: entries)
    }
  }

  private func model(_ repository: Repository) -> SourceControlModel {
    SourceControlModel(root: "/repo/app") { _ in
      repository.status
    } change: { _, change in
      switch change {
      case let .stage(files): repository.requests.append("stage \(files ?? ["*"])")
      case let .unstage(files): repository.requests.append("unstage \(files ?? ["*"])")
      case let .discard(files): repository.requests.append("discard \(files)")
      }
      return repository.status
    }
  }

  @Test func groupsConflictsStagedAndUnstagedChangesLikeAnEditor() async {
    let repository = Repository([
      ServerGitStatusEntry(path: "b.swift", staged: .modified, unstaged: .modified),
      ServerGitStatusEntry(path: "conflict.swift", unstaged: .conflicted),
      ServerGitStatusEntry(path: "new.swift", oldPath: "old.swift", staged: .renamed),
      ServerGitStatusEntry(path: "a.swift", unstaged: .untracked),
    ])
    let model = model(repository)

    await model.refresh()

    #expect(model.merge.map(\.id) == ["merge:conflict.swift"])
    #expect(model.staged.map(\.id) == ["staged:b.swift", "staged:new.swift"])
    #expect(model.changes.map(\.id) == ["changes:a.swift", "changes:b.swift"])
    #expect(model.count == 4)
    #expect(model.absolutePath(model.changes[0]) == "/repo/a.swift")
  }

  @Test func unstagingARenameTakesBackBothPathsAndShowsTheAnsweredStatus() async throws {
    let repository = Repository([ServerGitStatusEntry(path: "new.swift", oldPath: "old.swift", staged: .renamed)])
    let model = model(repository)
    await model.refresh()
    let rename = try #require(model.staged.first)
    repository.status = ServerGitStatus(
      repositoryRoot: "/repo", branch: "main",
      entries: [
        ServerGitStatusEntry(path: "new.swift", unstaged: .untracked),
        ServerGitStatusEntry(path: "old.swift", unstaged: .deleted),
      ])

    await model.unstage([rename])

    #expect(repository.requests == [#"unstage ["new.swift", "old.swift"]"#])
    #expect(model.staged.isEmpty)
    #expect(model.changes.map(\.code) == [.untracked, .deleted])
  }
}
