import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

/// Launch builds the environment from state decoded off the main actor: the
/// first window still shows every cached machine, picker, draft, and setting,
/// but none of those payloads is read or decoded on the main thread.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ClientLaunchSnapshotTests {
  @Test("A launch environment shows the previous launch's state without reading it on the main thread")
  func environmentAdoptsOffMainSnapshot() async throws {
    let store = MainThreadReadRecordingStore()
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/launch-snapshot"))
    let session = ChatSession(projectId: project.id, serverId: "local", title: "Cached chat")
    let workspace = Workspace(
      name: "Launch workspace", rootDirectory: "/tmp/launch-snapshot", serverId: "local",
      projectId: project.id, centerTree: .leaf(.centerInitial(sessionId: session.id)), isServerSynced: true)

    // The previous launch: synced a machine, inspected its harnesses, left
    // an unsent draft, finished onboarding, then quit after its saves landed.
    await NavigationFixture(persistence: store.base)
      .install(projects: [project], sessions: [session], workspaces: [workspace], cursor: 0)
    ConfigOptionCache(store: store.base).store([codexCapability()], forServer: "local")
    ComposerDraftStore(store: store.base)
      .saveDraft(.init(projectId: project.id, projectServerId: "local", composerText: "unsent"), forServer: "local")
    AppSettingsModel(store: store.base).completeOnboarding(importExternalSessions: false)
    PersistenceEncoding.drain()

    store.startRecording()
    let launchSnapshot = await Task.detached { ClientLaunchSnapshot.read(from: store) }.value
    let environment = AppEnvironment(
      navigationPersistence: store,
      launchSnapshot: launchSnapshot,
      configCache: ConfigOptionCache(store: store, launchSnapshot: launchSnapshot),
      composerDrafts: ComposerDraftStore(
        store: store, attachmentFiles: .temporary(), launchSnapshot: launchSnapshot),
      settings: AppSettingsModel(store: store, launchSnapshot: launchSnapshot)
    )

    #expect(environment.navigationStore.hasCache(for: "local"))
    #expect(environment.projectList.sessions.map(\.id) == [session.id])
    #expect(environment.workspaces.workspace(id: workspace.id)?.name == "Launch workspace")
    #expect(environment.configCache.capabilities(forServer: "local").map(\.harness.id) == ["codex"])
    #expect(environment.composerDrafts.draft(forServer: "local")?.composerText == "unsent")
    #expect(environment.settings.hasCompletedOnboarding)
    let launchKeyPrefixes = [
      NavigationCacheStore.keyPrefix, NavigationCacheStore.indexKey, ConfigOptionCache.defaultKey,
      ComposerDraftStore.defaultKey, ComposerDraftStore.defaultPaneKey, "settings",
    ]
    #expect(
      store.keysReadOnMainThread.filter { key in launchKeyPrefixes.contains { key.hasPrefix($0) } } == [])
  }

  private func codexCapability() -> ServerHarnessCapability {
    ServerHarnessCapability(
      harness: ServerHarness(
        id: "codex", name: "Codex", symbolName: "sparkle", source: "registry", launchKind: "executable",
        enabled: true, readiness: ServerHarnessReadiness(state: "ready")),
      modes: nil,
      configOptions: []
    )
  }
}

/// Records which keys were read on the main thread once recording starts.
private final class MainThreadReadRecordingStore: PersistenceStore, @unchecked Sendable {
  let base = InMemoryStore()
  private let lock = NSLock()
  private var isRecording = false
  private var mainThreadReads: [String] = []

  var keysReadOnMainThread: [String] { lock.withLock { mainThreadReads } }

  func startRecording() { lock.withLock { isRecording = true } }

  func loadData(forKey key: String) -> Data? {
    if Thread.isMainThread {
      lock.withLock { if isRecording { mainThreadReads.append(key) } }
    }
    return base.loadData(forKey: key)
  }

  func saveData(_ data: Data, forKey key: String) throws { try base.saveData(data, forKey: key) }

  func removeData(forKey key: String) throws { try base.removeData(forKey: key) }
}
