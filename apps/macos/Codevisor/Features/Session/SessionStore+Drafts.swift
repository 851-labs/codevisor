import CodevisorCore

extension SessionStore {
  func draft(project: Project) -> SessionController {
    if let draft = draftsByServer[project.serverId], draft.serverSession == nil {
      return draft
    }
    if let draft = draftsByServer.values.first(where: {
      $0.serverSession == nil && $0.project.serverId == project.serverId
    }) {
      return draft
    }
    let persistedMatch =
      environment.composerDrafts.draft(forServer: project.serverId).map {
        (slotServerId: project.serverId, draft: $0)
      } ?? environment.composerDrafts.draft(targetingServer: project.serverId)
    let persisted = persistedMatch?.draft
    let draftSlotServerId = persistedMatch?.slotServerId ?? project.serverId
    let restoredProject =
      persisted.flatMap { saved in
        var canonical = saved
        let savedServerId = saved.projectServerId ?? project.serverId
        canonical.projectServerId =
          environment.machines.canonicalComposerMachineId(for: savedServerId)
          ?? savedServerId
        return canonical.restoredProject(
          in: environment.projectList.projects,
          defaultServerId: project.serverId
        )
      } ?? environment.composerDefaults.lastProjectId(forServer: project.serverId).flatMap {
        rememberedId in
        environment.projectList.fleetActiveProjects.first {
          $0.serverId == project.serverId && $0.id == rememberedId && !$0.isScratch
        }
      } ?? project
    if !restoredProject.isRunTargetPlaceholder {
      environment.composerDefaults.rememberNewWorkspaceProject(
        serverId: restoredProject.serverId,
        projectId: restoredProject.id
      )
    }
    let controller = SessionController(
      project: restoredProject,
      configCache: environment.configCache,
      composerDefaults: environment.composerDefaults,
      serverClient: environment.machines.client(for: restoredProject.serverId),
      machines: environment.machines,
      notificationDelivery: notificationDelivery,
      attachmentFiles: environment.composerDrafts.attachmentFiles
    )
    controller.applyComposerDefaults()
    controller.wantsNewWorktree = environment.prefersNewWorktree(for: restoredProject)
    if let persisted { controller.restoreDraft(persisted) }
    enableDraftPersistence(for: controller, slotServerId: draftSlotServerId)
    draftsByServer[draftSlotServerId] = controller
    return controller
  }
}
