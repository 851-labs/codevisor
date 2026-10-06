import CodevisorCore
import Foundation
import Observation

/// Codevisor's skill store as one machine reports it. The store syncs
/// across devices, so any reachable machine's list is the list.
@MainActor @Observable
public final class SkillListModel {
  public private(set) var skills: [ServerSkill] = []
  public private(set) var isLoading = true
  public private(set) var loadFailed = false

  /// Discards answers from a load that a newer one has replaced.
  @ObservationIgnored private var loadGeneration = 0

  public init() {}

  public func load(client: any CodevisorServerClienting) async {
    loadGeneration &+= 1
    let generation = loadGeneration
    isLoading = true
    let list = try? await client.listSkills()
    guard generation == loadGeneration else { return }
    if let list {
      show(list.skills)
    } else {
      isLoading = false
      loadFailed = true
    }
  }

  /// Adopts the list a mutation returned, so the page reflects the change
  /// without another round trip. It supersedes any load still in flight.
  public func show(_ skills: [ServerSkill]) {
    loadGeneration &+= 1
    isLoading = false
    loadFailed = false
    self.skills = skills.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
}
