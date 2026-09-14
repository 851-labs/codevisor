import Foundation

extension WorkspaceSyncModel {
  /// Persist before starting I/O, so rendering and a subsequent drag see the
  /// new position immediately. A disconnected move survives app termination.
  @discardableResult
  public func reorderWorkspace(
    id: UUID, visibleIDs: [UUID], client: (any CodevisorServerClienting)?
  ) -> Task<Void, Never>? {
    guard var workspace = repository.workspace(id: id),
      let position = WorkspaceSidebarOrder.position(for: id, in: visibleIDs, workspaces: repository.loadAll()),
      position != workspace.effectiveSidebarPosition
    else { return nil }
    workspace.pendingSidebarPosition = position
    workspace.pendingSidebarOrderRevision = workspace.sidebarOrderRevision
    repository.saveWithSidebarOrder(workspace)
    refreshGenerationByServer[workspace.serverId, default: 0] &+= 1
    noteLocalMutation()
    guard let client else { return nil }
    return publishWorkspaceOrder(id: id, client: client)
  }

  func retryWorkspaceOrders(serverId: String, client: any CodevisorServerClienting) {
    for workspace in repository.loadAll()
    where workspace.serverId == serverId && workspace.pendingSidebarPosition != nil {
      _ = publishWorkspaceOrder(id: workspace.id, client: client)
    }
  }

  /// At most one request per workspace is in flight. Intermediate drag
  /// positions coalesce, while unrelated workspaces can sync independently.
  private func publishWorkspaceOrder(id: UUID, client: any CodevisorServerClienting) -> Task<Void, Never> {
    if let task = workspaceOrderTasks[id] { return task }
    let task = Task { [weak self] in
      guard let self else { return }
      defer { workspaceOrderTasks[id] = nil }
      while let workspace = repository.workspace(id: id),
        let position = workspace.pendingSidebarPosition
      {
        do {
          if workspace.sidebarOrderRevision == 0 {
            guard let record = try await client.upsertWorkspace(Self.serverWorkspace(from: workspace)),
              let revision = record.sidebarOrderRevision, revision > 0,
              var current = repository.workspace(id: id)
            else { return }
            Self.applyMetadata(record, to: &current)
            repository.saveWithSidebarOrder(current)
            noteLocalMutation()
            continue
          }
          let attempt =
            workspace.sidebarOrderAttempt
            ?? WorkspaceOrderAttempt(
              position: position,
              expectedRevision: workspace.pendingSidebarOrderRevision ?? workspace.sidebarOrderRevision
            )
          var sending = workspace
          sending.sidebarOrderAttempt = attempt
          repository.saveWithSidebarOrder(sending)
          let record = try await client.reorderWorkspace(
            id: id, position: attempt.position, expectedRevision: attempt.expectedRevision
          )
          guard var current = repository.workspace(id: id), current.serverId == workspace.serverId else { return }
          Self.applyMetadata(record, to: &current)
          let accepted = record.sidebarPosition == attempt.position
          if !accepted || current.pendingSidebarPosition == attempt.position {
            // A concurrent client won, or this was our final move. Never
            // retry a stale intent against a newer client's revision.
            current.pendingSidebarPosition = nil
            current.pendingSidebarOrderRevision = nil
          } else {
            current.pendingSidebarOrderRevision = record.sidebarOrderRevision
          }
          current.sidebarOrderAttempt = nil
          repository.saveWithSidebarOrder(current)
          refreshGenerationByServer[current.serverId, default: 0] &+= 1
          noteLocalMutation()
        } catch {
          // Retain the intent and its original revision for reconnect. An
          // ambiguous response is safe: repeating the CAS cannot apply twice.
          Log.sync.error("Failed to sync workspace order: \(String(describing: error), privacy: .public)")
          return
        }
      }
    }
    workspaceOrderTasks[id] = task
    return task
  }
}
