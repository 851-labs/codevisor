import Foundation

@MainActor
public struct ProjectCloneRequest {
  public let plan: ProjectMachineSetup.Plan
  public let setup: ProjectMachineSetup
  public let projectId: UUID
  weak var projectList: ProjectListModel?

  public init(
    plan: ProjectMachineSetup.Plan,
    setup: ProjectMachineSetup,
    projectList: ProjectListModel?,
    projectId: UUID = UUID()
  ) {
    self.plan = plan
    self.setup = setup
    self.projectList = projectList
    self.projectId = projectId
  }

  var provisionalProject: Project {
    Project(
      id: projectId,
      serverId: plan.targetServerId,
      name: plan.projectName,
      repoUrl: plan.repoUrl,
      worktreeBase: plan.worktreeBase,
      defaultRunLocation: plan.defaultRunLocation
    )
  }
}
