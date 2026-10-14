import CodevisorCore
import Foundation
import Observation

@MainActor @Observable
public final class SkillListModel {
  public private(set) var skills: [ServerSkill] = []
  public private(set) var isLoading = true
  public private(set) var loadFailed = false

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

  public func show(_ skills: [ServerSkill]) {
    loadGeneration &+= 1
    isLoading = false
    loadFailed = false
    self.skills = skills.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
}
