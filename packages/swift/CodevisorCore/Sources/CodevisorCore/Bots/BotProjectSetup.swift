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

  public func dismiss() {
    guard let setup, !setup.isRunning else { return }

    setup.cancel()
  }
}
