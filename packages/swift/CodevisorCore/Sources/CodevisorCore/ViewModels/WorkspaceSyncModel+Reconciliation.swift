import Foundation

extension WorkspaceSyncModel {
  func reconcile(
    _ records: [ServerWorkspace],
    paneRecords: [ServerWorkspacePane]?,
    protectedLocalPaneIds: Set<UUID>,
    assignments: [UUID: UUID],
    serverId: String
  ) {
    let sessionOrder = Dictionary(
      uniqueKeysWithValues: projectList.sessions
        .filter { $0.serverId == serverId }
        .enumerated()
        .map { ($0.element.id, $0.offset) }
    )
    let sessionsByWorkspace = Dictionary(grouping: assignments.keys) { assignments[$0]! }
      .mapValues { ids in
        ids.sorted { sessionOrder[$0, default: .max] < sessionOrder[$1, default: .max] }
      }

    var changed = false
    var remoteIds = Set<UUID>()

    if !assignments.isEmpty {
      sessionsInvalidatedByWorkspaceDeletion[serverId]?.subtract(assignments.keys)
    }

    for record in records {
      guard let id = UUID(uuidString: record.id),
        let projectId = UUID(uuidString: record.projectId),
        let createdAt = Self.date(from: record.createdAt)
      else {
        Log.sync.error("Dropping unmappable server workspace \(record.id, privacy: .public)")
        continue
      }
      remoteIds.insert(id)
      let sessionIds = sessionsByWorkspace[id] ?? []
      let worktreeName = sessionIds.lazy.compactMap { sessionId in
        self.projectList.sessions.first(where: {
          $0.id == sessionId && $0.serverId == serverId
        })?.worktreeName
      }.first
      let existing = repository.workspace(id: id)
      let migrationSource =
        existing == nil
        ? sessionIds.lazy.compactMap { sessionId -> Workspace? in
          guard let oldId = self.repository.workspaceId(forSession: sessionId), oldId != id else {
            return nil
          }
          guard let source = self.repository.workspace(id: oldId),
            !source.chatSessionIds.isEmpty,
            source.chatSessionIds.allSatisfy({ assignments[$0] == id })
          else {
            return nil
          }
          return source
        }.first
        : nil

      var workspace: Workspace
      if let existing {
        workspace = existing
      } else if let source = migrationSource {
        workspace = Workspace(
          id: id,
          name: record.hasCustomName ? record.name : source.name,
          hasCustomName: record.hasCustomName || source.hasCustomName,
          rootDirectory: record.rootDirectory ?? source.rootDirectory,
          worktreeName: source.worktreeName ?? worktreeName,
          serverId: serverId,
          projectId: projectId,
          centerTabs: source.centerTabs,
          selectedCenterTabId: source.selectedCenterTabId,
          bottomGroup: source.bottomGroup,
          createdAt: createdAt,
          isArchived: record.isArchived,
          isServerSynced: true
        )
      } else {
        workspace = Self.makeWorkspace(
          id: id,
          projectId: projectId,
          serverId: serverId,
          record: record,
          createdAt: createdAt,
          worktreeName: worktreeName,
          sessionIds: sessionIds,
          usesPaneRegistry: paneRecords != nil
        )
      }

      // A native-only custom name predating workspace sync must not be
      // erased by the server's generated project/worktree default.
      // Once the server carries an explicit name, it is authoritative.
      if !workspace.hasCustomName || record.hasCustomName {
        workspace.name = record.name
        workspace.hasCustomName = record.hasCustomName
      }
      workspace.rootDirectory = record.rootDirectory ?? workspace.rootDirectory
      workspace.worktreeName = workspace.worktreeName ?? worktreeName
      workspace.isArchived = record.isArchived
      workspace.isServerSynced = true

      if let paneRecords {
        var paneProtection = protectedLocalPaneIds
        let stableRecords = stablePaneSnapshot(
          paneRecords.filter {
            $0.workspaceId.caseInsensitiveCompare(record.id) == .orderedSame
          },
          workspaceId: id,
          protectedLocalPaneIds: &paneProtection
        )
        Self.reconcilePanes(
          in: &workspace,
          records: stableRecords,
          protectedLocalPaneIds: paneProtection
        )
      } else {
        for sessionId in sessionIds where workspace.tabId(containingChat: sessionId) == nil {
          workspace.centerTabs.append(
            WorkspaceTab(root: .leaf(.centerInitial(sessionId: sessionId)))
          )
        }
      }

      if existing != workspace || migrationSource != nil {
        repository.save(workspace)
        changed = true
      }
      if let source = migrationSource, source.id != id {
        repository.delete(id: source.id)
        changed = true
      }
    }

    // Only identities previously confirmed by the server participate in
    // snapshot deletion. Legacy/client-only layouts survive older servers
    // and are adopted once a session publishes their workspace id.
    for workspace in repository.loadAll()
    where
      workspace.serverId == serverId
      && workspace.isServerSynced
      && !remoteIds.contains(workspace.id)
    {
      sessionsInvalidatedByWorkspaceDeletion[serverId, default: []]
        .formUnion(workspace.chatSessionIds)
      repository.delete(id: workspace.id)
      changed = true
    }

    // A legacy automatic workspace can be superseded by multiple
    // authoritative identities. Once every chat routes elsewhere it no
    // longer owns navigation or layout state and can be removed safely.
    for workspace in repository.loadAll()
    where
      workspace.serverId == serverId
      && !workspace.isServerSynced
      && !workspace.chatSessionIds.isEmpty
      && workspace.chatSessionIds.allSatisfy({ sessionId in
        guard let assigned = assignments[sessionId] else { return false }
        return assigned != workspace.id
      })
    {
      repository.delete(id: workspace.id)
      changed = true
    }

    if changed { revision &+= 1 }
  }

  /// Filters a pane snapshot through the optimistic/confirmed revision
  /// barrier. A matching promoted renderer acknowledges the local mutation;
  /// lower revisions and missing pending ids preserve the current local
  /// descriptor instead of causing a visible rollback.
  private func stablePaneSnapshot(
    _ records: [ServerWorkspacePane],
    workspaceId: UUID,
    protectedLocalPaneIds: inout Set<UUID>
  ) -> [ServerWorkspacePane] {
    var stable: [ServerWorkspacePane] = []
    var observedIds = Set<UUID>()
    for record in records {
      guard let paneId = UUID(uuidString: record.id) else {
        stable.append(record)
        continue
      }
      observedIds.insert(paneId)
      let key = PanePublicationKey(workspaceId: workspaceId, paneId: paneId)
      if optimisticPaneDeletions.contains(key) { continue }
      let remoteRevision = record.revision ?? 0
      if remoteRevision < confirmedPaneRevisions[key, default: 0] {
        protectedLocalPaneIds.insert(paneId)
        continue
      }
      if let desired = optimisticPaneMutations[key] {
        if Self.descriptor(from: record) == desired {
          optimisticPaneMutations.removeValue(forKey: key)
          confirmedPaneRevisions[key] = max(
            confirmedPaneRevisions[key, default: 0],
            remoteRevision
          )
          stable.append(record)
        } else {
          protectedLocalPaneIds.insert(paneId)
        }
        continue
      }
      confirmedPaneRevisions[key] = max(
        confirmedPaneRevisions[key, default: 0],
        remoteRevision
      )
      stable.append(record)
    }
    for (key, _) in optimisticPaneMutations
    where key.workspaceId == workspaceId && !observedIds.contains(key.paneId) {
      protectedLocalPaneIds.insert(key.paneId)
    }
    for key in Array(optimisticPaneDeletions)
    where key.workspaceId == workspaceId && !observedIds.contains(key.paneId) {
      optimisticPaneDeletions.remove(key)
      confirmedPaneRevisions.removeValue(forKey: key)
    }
    return stable
  }

  func noteConfirmedRevision(_ pane: ServerWorkspacePane) {
    guard let workspaceId = UUID(uuidString: pane.workspaceId),
      let paneId = UUID(uuidString: pane.id)
    else { return }
    let key = PanePublicationKey(workspaceId: workspaceId, paneId: paneId)
    confirmedPaneRevisions[key] = max(
      confirmedPaneRevisions[key, default: 0],
      pane.revision ?? 0
    )
  }
}
