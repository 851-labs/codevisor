import Foundation
import Observation

/// Editable worktree settings for one checkout in project settings.
/// Operations are supplied by the caller so each editor stays pinned to
/// its checkout's machine and can be exercised without a live server.
@MainActor
@Observable
public final class ProjectWorktreeSettingsModel {
  public private(set) var branches: [ServerProjectGitBranch] = []
  public var selectedBase: ProjectWorktreeBase?
  public private(set) var savedBase: ProjectWorktreeBase?
  public private(set) var isLoading = true
  public private(set) var isSaving = false
  public private(set) var errorMessage: String?
  @ObservationIgnored private var loadGeneration = 0

  public init(worktreeBase: ProjectWorktreeBase?) {
    selectedBase = worktreeBase
    savedBase = worktreeBase
  }

  public var effectiveSelectedBase: ProjectWorktreeBase {
    selectedBase ?? ProjectWorktreeBase(remote: "origin", branch: "main")
  }

  public var hasChanges: Bool { selectedBase != savedBase }

  /// Refreshes and edits from another window update the baseline without
  /// discarding an unsaved selection in this editor.
  public func receive(_ base: ProjectWorktreeBase?) {
    guard !isSaving else { return }
    let wasEdited = hasChanges
    savedBase = base
    if !wasEdited { selectedBase = base }
  }

  public func revert() {
    guard !isSaving else { return }
    selectedBase = savedBase
    errorMessage = nil
  }

  public func load(using operation: () async throws -> [ServerProjectGitBranch]) async {
    loadGeneration += 1
    let generation = loadGeneration
    isLoading = true
    errorMessage = nil
    defer {
      if generation == loadGeneration { isLoading = false }
    }
    do {
      let loaded = try await operation()
      guard !Task.isCancelled, generation == loadGeneration else { return }
      branches = loaded
    } catch {
      guard !Task.isCancelled, generation == loadGeneration else { return }
      errorMessage = serverErrorMessage(error)
    }
  }

  /// Returns true when saved (or unchanged); errors retain the selection
  /// for retry. Nil remains nil until the user explicitly picks a branch.
  public func save(
    using operation: (ProjectWorktreeBase?) async throws -> ProjectWorktreeBase?
  ) async -> Bool {
    guard !isSaving, !isLoading else { return false }
    guard hasChanges else { return true }
    let requested = selectedBase
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      let saved = try await operation(requested)
      savedBase = saved
      if selectedBase == requested { selectedBase = saved }
      return true
    } catch {
      errorMessage = serverErrorMessage(error)
      return false
    }
  }
}
