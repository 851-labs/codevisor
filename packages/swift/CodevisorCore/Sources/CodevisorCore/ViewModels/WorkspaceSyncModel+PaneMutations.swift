import Foundation

extension WorkspaceSyncModel {
  /// Publishes content identity only. Selection, tab order, and split
  /// placement remain in the local workspace repository.
  public func publishPane(
    _ pane: PaneDescriptorState,
    workspaceId: UUID,
    client: any CodevisorServerClienting
  ) {
    let key = PanePublicationKey(workspaceId: workspaceId, paneId: pane.id)
    optimisticPaneDeletions.remove(key)
    optimisticPaneMutations[key] = pane
    enqueuePaneMutation(
      PendingPaneMutation(
        paneId: pane.id,
        workspaceId: workspaceId,
        client: client,
        operation: .upsert(pane)
      )
    )
  }

  /// The pane is already a chat in the device-local layout when this is
  /// called. The optimistic barrier is installed synchronously, then the
  /// server converts that exact id and attaches the deferred session as one
  /// observable mutation.
  public func promotePaneToChat(
    _ pane: PaneDescriptorState,
    session: ChatSession,
    workspaceId: UUID,
    client: any CodevisorServerClienting
  ) {
    let key = PanePublicationKey(workspaceId: workspaceId, paneId: pane.id)
    optimisticPaneDeletions.remove(key)
    optimisticPaneMutations[key] = pane
    enqueuePaneMutation(
      PendingPaneMutation(
        paneId: pane.id,
        workspaceId: workspaceId,
        client: client,
        operation: .promoteChat(pane, session)
      )
    )
  }

  private func enqueuePaneMutation(_ mutation: PendingPaneMutation) {
    let key = PanePublicationKey(
      workspaceId: mutation.workspaceId,
      paneId: mutation.paneId
    )
    pendingPaneMutations[key, default: []].append(mutation)
    guard publishingPaneKeys.insert(key).inserted else { return }
    Task { await drainPaneMutations(for: key) }
  }

  private func drainPaneMutations(for key: PanePublicationKey) async {
    defer { publishingPaneKeys.remove(key) }
    // New Tab, its promoted renderer, and its close intentionally share an
    // id. Preserve the exact user-command order so an immediate close can
    // never reach the server before the create it is closing.
    while var queue = pendingPaneMutations[key], !queue.isEmpty {
      let mutation = queue.removeFirst()
      if queue.isEmpty {
        pendingPaneMutations.removeValue(forKey: key)
      } else {
        pendingPaneMutations[key] = queue
      }
      switch mutation.operation {
      case .upsert, .promoteChat:
        await performPanePublication(mutation)
      case .close:
        await performPaneClose(
          id: mutation.paneId,
          workspaceId: mutation.workspaceId,
          client: mutation.client
        )
      }
    }
  }

  private func performPanePublication(_ mutation: PendingPaneMutation) async {
    let pane: PaneDescriptorState
    switch mutation.operation {
    case let .upsert(candidate), let .promoteChat(candidate, _):
      pane = candidate
    case .close:
      return
    }
    let workspaceId = mutation.workspaceId
    let client = mutation.client
    guard let workspace = repository.workspace(id: workspaceId) else { return }
    do {
      guard
        let targetWorkspaceId = try await publishWorkspaceIfNeeded(
          workspace,
          client: client
        )
      else { return }
      if case let .promoteChat(_, session) = mutation.operation {
        let candidate = Self.serverPane(
          from: pane,
          workspaceId: targetWorkspaceId,
          createdAt: Date()
        )
        if let promotion = try await client.promoteWorkspacePaneToChat(
          candidate,
          session: session
        ) {
          noteConfirmedRevision(promotion.pane)
          repository.markMigrationPerformed(
            Self.panePublicationKey(serverId: workspace.serverId, paneId: pane.id)
          )
        } else {
          // Rolling-upgrade fallback. The optimistic barrier still
          // prevents the intermediate placeholder snapshot from
          // repainting the initiating client.
          _ = try await client.upsertSession(session)
          if let uploaded = try await client.upsertWorkspacePane(candidate) {
            noteConfirmedRevision(uploaded)
            repository.markMigrationPerformed(
              Self.panePublicationKey(serverId: workspace.serverId, paneId: pane.id)
            )
          }
          _ = try await client.upsertSession(session, workspaceId: targetWorkspaceId)
        }
        await refreshFromServer(serverId: workspace.serverId, client: client)
        return
      }
      if pane.kind == .chat,
        let sessionId = pane.chatSessionId,
        let session = projectList.sessions.first(where: {
          $0.serverId == workspace.serverId && $0.id == sessionId
        })
      {
        // Establish the session without membership first. Publishing
        // the explicit pane then assigning membership prevents the
        // server's legacy membership bridge from briefly synthesizing
        // a second chat pane keyed by the session id.
        _ = try await client.upsertSession(session)
        if let uploaded = try await client.upsertWorkspacePane(
          Self.serverPane(from: pane, workspaceId: targetWorkspaceId, createdAt: Date())
        ) {
          noteConfirmedRevision(uploaded)
          repository.markMigrationPerformed(
            Self.panePublicationKey(serverId: workspace.serverId, paneId: pane.id)
          )
        }
        _ = try await client.upsertSession(session, workspaceId: targetWorkspaceId)
        return
      }
      if let uploaded = try await client.upsertWorkspacePane(
        Self.serverPane(from: pane, workspaceId: targetWorkspaceId, createdAt: Date())
      ) {
        noteConfirmedRevision(uploaded)
        repository.markMigrationPerformed(
          Self.panePublicationKey(serverId: workspace.serverId, paneId: pane.id)
        )
      }
    } catch {
      let key = PanePublicationKey(workspaceId: workspaceId, paneId: pane.id)
      if optimisticPaneMutations[key] == pane {
        optimisticPaneMutations.removeValue(forKey: key)
      }
      Log.sync.error(
        "Failed to publish workspace pane \(pane.id, privacy: .public): \(String(describing: error), privacy: .public)"
      )
    }
  }

  public func deletePane(
    id: UUID,
    workspaceId: UUID,
    optimisticReplacement: PaneDescriptorState? = nil,
    client: any CodevisorServerClienting
  ) {
    let key = PanePublicationKey(workspaceId: workspaceId, paneId: id)
    if let optimisticReplacement {
      optimisticPaneDeletions.remove(key)
      optimisticPaneMutations[key] = optimisticReplacement
    } else {
      optimisticPaneMutations.removeValue(forKey: key)
      optimisticPaneDeletions.insert(key)
    }
    enqueuePaneMutation(
      PendingPaneMutation(
        paneId: id,
        workspaceId: workspaceId,
        client: client,
        operation: .close
      )
    )
  }

  private func performPaneClose(
    id: UUID,
    workspaceId: UUID,
    client: any CodevisorServerClienting
  ) async {
    let key = PanePublicationKey(workspaceId: workspaceId, paneId: id)
    do {
      let replacement = try await client.closeWorkspacePane(
        workspaceId: workspaceId,
        paneId: id
      )
      if let replacement, let descriptor = Self.descriptor(from: replacement) {
        optimisticPaneDeletions.remove(key)
        optimisticPaneMutations.removeValue(forKey: key)
        noteConfirmedRevision(replacement)
        if var workspace = repository.workspace(id: workspaceId) {
          if !Self.replacePane(id: id, with: descriptor, in: &workspace) {
            let state = PaneGroupState(
              panes: [descriptor], selectedPaneId: descriptor.id, isVisible: true
            )
            workspace.centerTabs.append(WorkspaceTab(root: .leaf(state)))
          }
          Self.pruneEmptyCenterTabs(in: &workspace)
          Self.ensureUsableLayout(&workspace)
          repository.save(workspace)
          revision &+= 1
        }
      } else {
        optimisticPaneMutations.removeValue(forKey: key)
        confirmedPaneRevisions.removeValue(forKey: key)
        if var workspace = repository.workspace(id: workspaceId),
          Self.removePane(id: id, from: &workspace)
        {
          Self.ensureUsableLayout(&workspace)
          repository.save(workspace)
          revision &+= 1
        }
      }
    } catch {
      optimisticPaneMutations.removeValue(forKey: key)
      optimisticPaneDeletions.remove(key)
      Log.sync.error(
        "Failed to close workspace pane \(id, privacy: .public): \(String(describing: error), privacy: .public)"
      )
    }
  }

  /// Applies a live delete immediately; the next snapshot catches anything
  /// missed while disconnected.
  public func removePane(id: UUID, workspaceId: UUID, serverId: String) {
    let key = PanePublicationKey(workspaceId: workspaceId, paneId: id)
    optimisticPaneMutations.removeValue(forKey: key)
    optimisticPaneDeletions.remove(key)
    confirmedPaneRevisions.removeValue(forKey: key)
    guard var workspace = repository.workspace(id: workspaceId),
      workspace.serverId == serverId
    else { return }
    guard Self.removePane(id: id, from: &workspace) else { return }
    Self.ensureUsableLayout(&workspace)
    repository.save(workspace)
    revision &+= 1
  }
}
