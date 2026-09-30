import Foundation
import Observation

extension ProjectWorktreeBase {
  /// What a project that never chose a base branch starts worktrees from.
  public static let legacyDefault = ProjectWorktreeBase(remote: "origin", branch: "main")
}

extension ProjectGroup {
  /// The one branch new worktrees of this project start from on every
  /// machine: the choice recorded on its oldest git checkout that has one,
  /// else the legacy default. A checkout added later (or one that missed a
  /// change while offline) follows this, see `alignWorktreeBase(for:)`.
  public var worktreeBase: ProjectWorktreeBase {
    members.filter(\.isGitRepository).lazy.compactMap(\.worktreeBase).first ?? .legacyDefault
  }
}

/// The remote branches a project's worktrees can start from, merged across
/// every machine that has a checkout. Choosing one is a fleet-wide change
/// (`ProjectListModel.setWorktreeBase`); this only lists what can be chosen.
@MainActor
@Observable
public final class ProjectBaseBranchModel {
  public private(set) var branches: [ServerProjectGitBranch] = []
  public private(set) var isLoading = true
  /// The first machine that failed to list its branches. Branches the other
  /// machines listed are still offered.
  public private(set) var errorMessage: String?
  /// False when every checkout's machine was offline, so an empty list
  /// means "nothing to ask" rather than "no branches".
  public private(set) var reachedMachine = false
  @ObservationIgnored private var loadGeneration = 0

  private enum Listing: Sendable {
    case listed([ServerProjectGitBranch])
    case unreachable
    case failed(String)
  }

  public init() {}

  /// Lists each checkout's branches concurrently. `fetch` returns nil for a
  /// machine that can't be reached right now, which is skipped rather than
  /// reported. Branches keep the first machine's order; later machines only
  /// add what it lacks, and only the first machine's default is marked.
  public func load(
    _ checkouts: [Project],
    using fetch: @escaping @Sendable (Project) async throws -> [ServerProjectGitBranch]?
  ) async {
    loadGeneration += 1
    let generation = loadGeneration
    isLoading = true
    defer {
      if generation == loadGeneration { isLoading = false }
    }
    let results = await withTaskGroup(of: (Int, Listing).self) { group in
      for (index, checkout) in checkouts.enumerated() {
        group.addTask {
          do {
            guard let listed = try await fetch(checkout) else { return (index, .unreachable) }
            return (index, .listed(listed))
          } catch {
            return (index, .failed(serverErrorMessage(error)))
          }
        }
      }
      var ordered = [Listing](repeating: .unreachable, count: checkouts.count)
      for await (index, listing) in group { ordered[index] = listing }
      return ordered
    }
    guard !Task.isCancelled, generation == loadGeneration else { return }
    var merged: [ServerProjectGitBranch] = []
    var seen = Set<ProjectWorktreeBase>()
    var error: String?
    for listing in results {
      switch listing {
      case let .listed(listed):
        let isFirst = seen.isEmpty
        for branch in listed {
          guard seen.insert(branch.worktreeBase).inserted else { continue }
          var added = branch
          if !isFirst { added.isDefault = false }
          merged.append(added)
        }
      case .unreachable:
        continue
      case let .failed(message):
        error = error ?? message
      }
    }
    branches = merged
    errorMessage = error
    reachedMachine = results.contains {
      if case .unreachable = $0 { return false }
      return true
    }
  }
}
