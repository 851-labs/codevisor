import Foundation
import Observation

extension ProjectWorktreeBase {
  public static let legacyDefault = ProjectWorktreeBase(remote: "origin", branch: "main")
}

extension ProjectGroup {
  public var worktreeBase: ProjectWorktreeBase {
    members.filter(\.isGitRepository).lazy.compactMap(\.worktreeBase).first ?? .legacyDefault
  }

  public var defaultRunLocation: ProjectRunLocation? {
    members.filter(\.isGitRepository).lazy.compactMap(\.defaultRunLocation).first
  }
}

@MainActor
@Observable
public final class ProjectBaseBranchModel {
  public private(set) var branches: [ServerProjectGitBranch] = []
  public private(set) var isLoading = true
  public private(set) var errorMessage: String?
  public private(set) var reachedMachine = false
  @ObservationIgnored private var loadGeneration = 0

  private enum Listing: Sendable {
    case listed([ServerProjectGitBranch])
    case unreachable
    case failed(String)
  }

  public init() {}

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
