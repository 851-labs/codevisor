import Foundation

/// How this device arranges one workspace: its tabs, their splits, which tab
/// is selected, and any custom tab titles. Other devices arrange the same
/// workspace however they like.
public struct DeviceLayout: Codable, Equatable, Sendable {
  /// The machine that owns the workspace, so a snapshot from that machine can
  /// forget layouts for workspaces it no longer has.
  public var serverId: String
  public var tabs: [WorkspaceTab]
  public var selectedTabId: UUID

  public init(serverId: String, tabs: [WorkspaceTab], selectedTabId: UUID) {
    self.serverId = serverId
    self.tabs = tabs
    self.selectedTabId = selectedTabId
  }

  init(_ workspace: Workspace) {
    self.init(serverId: workspace.serverId, tabs: workspace.centerTabs, selectedTabId: workspace.selectedCenterTabId)
  }
}

/// A workspace the user started on this device that the server doesn't have
/// yet. It becomes a real workspace when its first chat opens: that request
/// creates the workspace and the chat's pane on the server in one step.
public struct WorkspaceDraft: Codable, Equatable, Sendable {
  public var id: UUID
  public var serverId: String
  public var projectId: UUID
  public var name: String
  public var rootDirectory: String?
  public var worktreeName: String?
  public var createdAt: Date
  /// Fixed when the draft is made so it stays put in the sidebar; the server
  /// assigns the real position when it creates the workspace.
  public var sidebarPosition: String?

  public init(
    id: UUID, serverId: String, projectId: UUID, name: String, rootDirectory: String?,
    worktreeName: String?, createdAt: Date, sidebarPosition: String? = nil
  ) {
    self.id = id
    self.serverId = serverId
    self.projectId = projectId
    self.name = name
    self.rootDirectory = rootDirectory
    self.worktreeName = worktreeName
    self.createdAt = createdAt
    self.sidebarPosition = sidebarPosition
  }
}

/// The client-owned half of navigation: per-workspace layouts and drafts.
///
/// Thread-safe because pane models persist layout through the workspace
/// repository from wherever they run; the main actor reads it back when it
/// rebuilds what the UI shows.
public final class DeviceLayoutStore: @unchecked Sendable {
  static let storageKey = "device-layout-v1"

  private struct Payload: Codable {
    var layouts: [UUID: DeviceLayout] = [:]
    var drafts: [UUID: WorkspaceDraft] = [:]
  }

  private let store: any PersistenceStore
  private let lock = NSLock()
  private let persistenceOwner = UUID()
  private var payload: Payload
  /// Change counters, so a rebuild can tell what changed without comparing
  /// layouts. Every mutation bumps the workspaces and machines it touched;
  /// `removeAll` bumps everything at once.
  private var allGeneration: UInt64 = 0
  private var machineGenerations: [String: UInt64] = [:]
  private var workspaceGenerations: [UUID: UInt64] = [:]

  public init(store: any PersistenceStore) {
    self.store = store
    if let data = store.loadData(forKey: Self.storageKey) {
      do {
        payload = try JSONDecoder().decode(Payload.self, from: data)
      } catch {
        handleCorruptPayload(store: store, key: Self.storageKey, data: data, error: error)
        payload = Payload()
      }
    } else {
      payload = Payload()
    }
  }

  public func layout(for workspaceId: UUID) -> DeviceLayout? {
    lock.withLock { payload.layouts[workspaceId] }
  }

  public var drafts: [WorkspaceDraft] {
    lock.withLock { Array(payload.drafts.values) }
  }

  public func draft(id: UUID) -> WorkspaceDraft? {
    lock.withLock { payload.drafts[id] }
  }

  func machineGeneration(_ serverId: String) -> UInt64 {
    lock.withLock { machineGenerations[serverId, default: 0] &+ allGeneration }
  }

  func workspaceGeneration(_ workspaceId: UUID) -> UInt64 {
    lock.withLock { workspaceGenerations[workspaceId, default: 0] &+ allGeneration }
  }

  /// Records a change; callers hold the lock.
  private func noteChange(workspaceId: UUID, serverIds: [String?]) {
    workspaceGenerations[workspaceId, default: 0] &+= 1
    for case let serverId? in serverIds { machineGenerations[serverId, default: 0] &+= 1 }
  }

  public func setLayout(_ layout: DeviceLayout, for workspaceId: UUID) {
    let changed = lock.withLock {
      let old = payload.layouts[workspaceId]
      guard old != layout else { return false }
      payload.layouts[workspaceId] = layout
      noteChange(workspaceId: workspaceId, serverIds: [layout.serverId, old?.serverId])
      return true
    }
    if changed { persist() }
  }

  public func addDraft(_ draft: WorkspaceDraft, layout: DeviceLayout) {
    lock.withLock {
      payload.drafts[draft.id] = draft
      payload.layouts[draft.id] = layout
      noteChange(workspaceId: draft.id, serverIds: [draft.serverId, layout.serverId])
    }
    persist()
  }

  /// The server now has this workspace; its layout stays, the draft goes.
  public func promoteDraft(id: UUID) {
    let changed = lock.withLock {
      guard let draft = payload.drafts.removeValue(forKey: id) else { return false }
      noteChange(workspaceId: id, serverIds: [draft.serverId])
      return true
    }
    if changed { persist() }
  }

  public func remove(workspaceId: UUID) {
    let changed = lock.withLock {
      let layout = payload.layouts.removeValue(forKey: workspaceId)
      let draft = payload.drafts.removeValue(forKey: workspaceId)
      guard layout != nil || draft != nil else { return false }
      noteChange(workspaceId: workspaceId, serverIds: [layout?.serverId, draft?.serverId])
      return true
    }
    if changed { persist() }
  }

  /// Forgets a machine's layouts for workspaces its latest complete snapshot
  /// no longer has. Only a full snapshot may drive this, so a machine that is
  /// merely offline never loses its arrangements. Drafts are kept.
  public func prune(serverId: String, keeping workspaceIds: Set<UUID>) {
    let changed = lock.withLock {
      let gone = payload.layouts.filter { id, layout in
        layout.serverId == serverId && !workspaceIds.contains(id) && payload.drafts[id] == nil
      }
      for id in gone.keys {
        payload.layouts.removeValue(forKey: id)
        noteChange(workspaceId: id, serverIds: [serverId])
      }
      return !gone.isEmpty
    }
    if changed { persist() }
  }

  public func removeAll() {
    lock.withLock {
      payload = Payload()
      allGeneration &+= 1
    }
    persist()
  }

  private func persist() {
    let snapshot = lock.withLock { payload }
    let store = store
    PersistenceEncoding.enqueueLatest(owner: persistenceOwner, key: Self.storageKey) {
      do {
        try store.saveData(PersistenceEncoding.encoder.encode(snapshot), forKey: Self.storageKey)
      } catch {
        Log.persistence.error("Failed to save device layouts: \(String(describing: error), privacy: .public)")
      }
    }
  }
}
