import Foundation
import Observation

@MainActor
@Observable
public final class BotProjectSetup {
  public private(set) var setup: ProjectMachineSetup?
  @ObservationIgnored private let environment: AppEnvironment

  init(environment: AppEnvironment) {
    self.environment = environment
  }

  public var isPresented: Bool {
    setup?.isPresented == true
  }

  func clone(_ group: ProjectGroup, to serverId: String, onCloned: @escaping (Project) -> Void) async {
    guard !isPresented else { return }

    let setup = ProjectMachineSetup(machines: environment.machines)
    setup.onFinished = { [weak setup] project in
      setup?.close()
      onCloned(project)
    }
    self.setup = setup
    await setup.prepare(
      group: group,
      targetServerId: serverId,
      preferredSource: environment.projectList.mostRecentlyUsedMember(of: group)
    )
  }

  func canClone(_ group: ProjectGroup, to serverId: String, retry: @escaping () -> Void) async -> Bool {
    guard !isPresented else { return false }

    let setup = ProjectMachineSetup(machines: environment.machines)
    let preferredSource = environment.projectList.mostRecentlyUsedMember(of: group)
    guard let plan = setup.clonePlan(group: group, targetServerId: serverId, preferredSource: preferredSource)
    else { return true }
    guard let failure = await setup.cloneAccessFailure(plan) else { return true }

    setup.retryHandler = retry
    self.setup = setup
    setup.present(plan, failure: failure)
    return false
  }

  public func dismiss() {
    guard let setup, !setup.isRunning else { return }

    setup.cancel()
  }
}
