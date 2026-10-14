import CodevisorCore
import Foundation
import Observation

public struct ReviewFileDiff: Identifiable, Equatable, Sendable {
  public var id: String { file.path }
  public let file: ServerGitDiffFile
  let rows: [LineDiff.Row]
  public let totals: LineDiff.Totals
  let revision: Int
  let maxLineNumber: Int

  init(file: ServerGitDiffFile) {
    self.file = file
    var hasher = Hasher()
    hasher.combine(file.path)
    hasher.combine(file.oldText)
    hasher.combine(file.newText)
    revision = hasher.finalize()
    if file.omitted != nil || (file.oldText == nil && file.newText == nil) {
      rows = []
    } else {
      rows = LineDiff.rows(old: file.oldText, new: file.newText ?? "")
    }
    maxLineNumber = rows.reduce(1) { max($0, $1.oldLine ?? 0, $1.newLine ?? 0) }
    totals = rows.reduce(into: LineDiff.Totals(added: 0, removed: 0)) { totals, row in
      switch row.kind {
      case .context: break
      case .added: totals.added += 1
      case .removed: totals.removed += 1
      }
    }
  }
}

public struct ReviewFailure: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case notRepository, noTurnYet, unknownBase, unmergedIndex, other
  }

  public let kind: Kind
  public let message: String

  init(_ error: any Error) {
    message = error.localizedDescription
    switch serverErrorCode(error) {
    case "not_git_repository": kind = .notRepository
    case "no_turn_snapshot": kind = .noTurnYet
    case "unknown_base": kind = .unknownBase
    case "unmerged_index": kind = .unmergedIndex
    default: kind = .other
    }
  }
}

@MainActor @Observable
public final class ReviewPaneModel {
  public let id: UUID
  public let rootPath: String
  public let machineId: String
  public let client: any CodevisorServerClienting
  public private(set) var preferences: ReviewPanePreferences
  public var projectBase: String? {
    didSet {
      guard projectBase != oldValue, preferences.mode == .branch, preferences.base == nil,
        hasLoaded || loadTask != nil
      else { return }
      reload()
    }
  }
  public private(set) var files: [ReviewFileDiff] = []
  public private(set) var truncated = false
  public private(set) var resolvedBase: String?
  public private(set) var failure: ReviewFailure?
  public private(set) var isLoading = false
  public private(set) var hasLoaded = false
  public private(set) var isStale = false
  public private(set) var refs: ServerGitRefs?
  public private(set) var isLoadingRefs = false
  public var collapsedFiles: Set<String> = []
  public var showsBranchPicker = false
  @ObservationIgnored private var revision: String?
  @ObservationIgnored public var onPreferencesChange: ((ReviewPanePreferences) -> Void)?
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var generation = 0

  public init(
    id: UUID,
    rootPath: String,
    machineId: String,
    client: any CodevisorServerClienting,
    preferences: ReviewPanePreferences = ReviewPanePreferences(),
    projectBase: String? = nil
  ) {
    self.id = id
    self.rootPath = rootPath
    self.machineId = machineId
    self.client = client
    self.preferences = preferences
    self.projectBase = projectBase
  }

  public var mode: ServerGitDiffMode { preferences.mode }

  public var requestedBase: String? { preferences.base ?? projectBase }

  public var baseDisplayName: String {
    requestedBase ?? resolvedBase ?? refs?.defaultBase ?? "Base Branch"
  }

  var branchChoices: [ServerGitRefs.Branch] {
    let loaded = refs?.branches ?? []
    guard !loaded.contains(where: { $0.name == baseDisplayName }) else { return loaded }
    return [ServerGitRefs.Branch(name: baseDisplayName, remote: false)] + loaded
  }

  public var totals: LineDiff.Totals {
    files.reduce(into: LineDiff.Totals(added: 0, removed: 0)) { result, file in
      result.added += file.totals.added
      result.removed += file.totals.removed
    }
  }

  public func setMode(_ mode: ServerGitDiffMode) {
    guard mode != preferences.mode else { return }
    update(ReviewPanePreferences(mode: mode, base: preferences.base, viewed: preferences.viewed))
  }

  public func setBase(_ base: String) {
    let override: String? = base == projectBase ? nil : base
    guard preferences.mode != .branch || override != preferences.base else { return }
    update(ReviewPanePreferences(mode: .branch, base: override, viewed: preferences.viewed))
  }

  public func apply(_ incoming: ReviewPanePreferences) {
    guard incoming != preferences else { return }
    let previouslyViewed = viewedIDs
    let comparesSame = incoming.comparesSame(as: preferences)
    preferences = incoming
    guard comparesSame else {
      isStale = hasLoaded
      reload()
      return
    }
    reconcileCollapse(previouslyViewed: previouslyViewed, knownIDs: Set(files.map(\.id)))
  }

  public func isViewed(_ file: ReviewFileDiff) -> Bool {
    preferences.isViewed(path: file.id, fingerprint: file.file.fingerprint)
  }

  public func toggleViewed(_ file: ReviewFileDiff) {
    let marking = !isViewed(file)
    preferences.setViewed(
      marking, path: file.id, fingerprint: file.file.fingerprint, current: Set(files.map(\.id)))
    if marking { collapsedFiles.insert(file.id) } else { collapsedFiles.remove(file.id) }
    onPreferencesChange?(preferences)
  }

  public var viewedCount: Int { files.filter(isViewed).count }

  private var viewedIDs: Set<String> { Set(files.filter(isViewed).map(\.id)) }

  private func reconcileCollapse(previouslyViewed: Set<String>, knownIDs: Set<String>) {
    for file in files {
      let viewed = isViewed(file)
      if viewed, !knownIDs.contains(file.id) || !previouslyViewed.contains(file.id) {
        collapsedFiles.insert(file.id)
      } else if !viewed, previouslyViewed.contains(file.id) {
        collapsedFiles.remove(file.id)
      }
    }
  }

  public func toggleCollapsed(_ file: ReviewFileDiff) {
    if collapsedFiles.remove(file.id) == nil { collapsedFiles.insert(file.id) }
  }

  public func loadIfNeeded() {
    guard !hasLoaded, loadTask == nil else { return }
    reload()
  }

  public func reload() {
    start(knownRevision: nil, quiet: false)
  }

  public func poll() {
    guard hasLoaded, loadTask == nil else { return }
    start(knownRevision: revision, quiet: true)
  }

  private func start(knownRevision: String?, quiet: Bool) {
    loadTask?.cancel()
    generation += 1
    let generation = generation
    let request = (path: rootPath, mode: preferences.mode, base: requestedBase)
    if !quiet { isLoading = true }
    loadTask = Task { [client] in
      let outcome: Result<(ServerGitDiff, [ReviewFileDiff]), any Error>
      do {
        let diff = try await client.gitDiff(
          path: request.path, mode: request.mode, base: request.base, revision: knownRevision)
        let prepared = await Task.detached(priority: .userInitiated) {
          diff.files.map(ReviewFileDiff.init(file:))
        }.value
        outcome = .success((diff, prepared))
      } catch {
        outcome = .failure(error)
      }
      guard !Task.isCancelled, generation == self.generation else { return }
      self.finish(outcome, quiet: quiet)
    }
  }

  public func loadRefs() async {
    guard !isLoadingRefs else { return }
    isLoadingRefs = true
    defer { isLoadingRefs = false }
    refs = try? await client.gitRefs(path: rootPath)
  }

  private func finish(_ outcome: Result<(ServerGitDiff, [ReviewFileDiff]), any Error>, quiet: Bool) {
    isLoading = false
    isStale = false
    loadTask = nil
    hasLoaded = true
    switch outcome {
    case let .success((diff, _)) where diff.unchanged == true:
      return
    case let .success((diff, prepared)):
      failure = nil
      revision = diff.revision
      let previouslyViewed = viewedIDs
      let knownIDs = Set(files.map(\.id))
      files = prepared
      truncated = diff.truncated
      resolvedBase = diff.base
      collapsedFiles.formIntersection(prepared.map(\.id))
      reconcileCollapse(previouslyViewed: previouslyViewed, knownIDs: knownIDs)
    case let .failure(error):
      if error is CancellationError || (quiet && failure == nil) { return }
      failure = ReviewFailure(error)
      revision = nil
      files = []
      truncated = false
      resolvedBase = nil
    }
  }

  private func update(_ next: ReviewPanePreferences) {
    preferences = next
    isStale = hasLoaded
    onPreferencesChange?(next)
    reload()
  }
}
