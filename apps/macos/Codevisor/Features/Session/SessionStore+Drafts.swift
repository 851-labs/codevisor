import CodevisorCore

extension SessionStore {
  /// Returns the retained draft controller for the new-chat page, restoring
  /// its disk snapshot first or seeding it from last-used composer defaults
  /// if none exists. The draft is retained until its first send promotes it
  /// to a real session, so unsent composer state survives navigation and
  /// relaunches.
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
        // The saved draft may target ANOTHER machine's project (the
        // picker is fleet-wide); older drafts carry no server id and
        // mean this machine. A configured machine's now-hidden cloud
        // twin is the same target under an obsolete identity.
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
        // A scratch folder is single-use: the next chat never starts in
        // the previous chat's folder. (A remembered "No project" is the
        // placeholder id, which matches nothing and falls through.)
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
      composerDefaultsScope: .newWorkspace(serverId: restoredProject.serverId),
      // The restored project's OWN machine — a retargeted draft keeps
      // talking to the machine it was pointed at across relaunches.
      serverClient: environment.machines.client(for: restoredProject.serverId),
      notificationDelivery: notificationDelivery
    )
    controller.applyComposerDefaults()
    // Fresh drafts start from the machine's remembered run-location
    // choice (worktrees only apply to git projects). Retained drafts
    // returned above keep whatever the user toggled.
    controller.wantsNewWorktree =
      restoredProject.isGitRepository
      && environment.composerDefaults.prefersWorktreeForNewWorkspaces(
        forServer: restoredProject.serverId
      )
    if let persisted { controller.restoreDraft(persisted) }
    enableDraftPersistence(for: controller, slotServerId: draftSlotServerId)
    draftsByServer[draftSlotServerId] = controller
    return controller
  }
}
