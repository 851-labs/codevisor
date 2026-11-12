import Foundation

public enum PaneChat: Equatable {
  case ready(ChatSession, Project)
  case connecting(PaneChatMachine)
  case offline(PaneChatMachine)
  case missing
}

public struct PaneChatMachine: Equatable, Sendable {
  public let id: String
  public let name: String
}

@MainActor
public struct PaneChatResolver {
  private let projectList: ProjectListModel
  private let machines: MachineController

  public init(projectList: ProjectListModel, machines: MachineController) {
    self.projectList = projectList
    self.machines = machines
  }

  public func chat(_ sessionId: UUID, on machineId: String) -> PaneChat {
    if let listed = listedChat(sessionId, on: machineId) { return listed }
    guard machines.availability(for: machineId) != .ready else { return .missing }

    return isOffline(machineId) ? .offline(machine(machineId)) : .connecting(machine(machineId))
  }

  private func listedChat(_ sessionId: UUID, on machineId: String) -> PaneChat? {
    guard let session = projectList.session(sessionId, serverId: machineId),
      let project = projectList.projects.first(where: { $0.serverId == machineId && $0.id == session.projectId })
    else { return nil }
    return .ready(session, project)
  }

  private func isOffline(_ machineId: String) -> Bool {
    guard machines.availability(for: machineId) != .ready else { return false }

    return machines.statusByMachineId[machineId]?.isReachable == false
      || machines.cloudMachine(forMachineId: machineId)?.online == false
  }

  private func machine(_ machineId: String) -> PaneChatMachine {
    PaneChatMachine(id: machineId, name: machines.machine(for: machineId)?.name ?? "This machine")
  }
}
