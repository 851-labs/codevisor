import Foundation
import Testing
import CodevisorTestSupport

@testable import CodevisorCore

/// The status probe caches the server's advertised capabilities so views
/// can gate on them synchronously instead of re-probing on every mount.
@MainActor
@Suite("MachineStatus features")
struct MachineStatusFeaturesTests {
  private func makeController(fake: SyncFakeServerClient) throws -> (MachineController, CodevisorMachine) {
    let remote = CodevisorMachine(
      id: "remote-a",
      name: "remote-a",
      baseURL: URL(string: "http://remote-a.test:49361")!,
      kind: "remote"
    )
    let store = InMemoryStore()
    try store.saveData(
      JSONEncoder().encode(MachineRegistry(selectedMachineId: "local", remoteMachines: [remote])),
      forKey: "machines"
    )
    let controller = MachineController(
      store: store,
      projectList: ProjectListModel(
        projectRepository: DefaultProjectRepository(store: InMemoryStore()),
        sessionRepository: DefaultSessionRepository(store: InMemoryStore())
      ),
      clientFactory: { machine in
        machine.id == remote.id ? fake : SyncFakeServerClient(projects: [], sessions: [])
      }
    )
    return (controller, remote)
  }

  @Test("Status probe caches the advertised feature list")
  func probeCachesFeatures() async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureInfoFeatures(["plugins-v1", "screen-sharing-v1"])
    let (controller, remote) = try makeController(fake: fake)

    await controller.refreshStatus(for: remote.id)

    let status = try #require(controller.statusByMachineId[remote.id])
    #expect(status.features == ["plugins-v1", "screen-sharing-v1"])
    #expect(status.supportsScreenSharing)
  }

  @Test("A server without a feature list advertises no capabilities")
  func missingFeaturesMeansNone() async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureInfoFeatures(nil)
    let (controller, remote) = try makeController(fake: fake)

    await controller.refreshStatus(for: remote.id)

    let status = try #require(controller.statusByMachineId[remote.id])
    #expect(status.features.isEmpty)
    #expect(!status.supportsScreenSharing)
  }

  @Test("Adopting a cloud identity keeps the probed features")
  func adoptingCloudIdentityKeepsFeatures() {
    let store = InMemoryStore()
    let controller = MachineController(
      store: store,
      projectList: ProjectListModel(
        projectRepository: DefaultProjectRepository(store: InMemoryStore()),
        sessionRepository: DefaultSessionRepository(store: InMemoryStore())
      ),
      clientFactory: { _ in SyncFakeServerClient(projects: [], sessions: []) }
    )
    controller.connection(for: CodevisorMachine.local.id).status = MachineStatus(
      isReachable: true, label: "Local 1.0.0", route: .direct, serverId: "local",
      features: ["screen-sharing-v1"]
    )

    controller.adoptLocalCloudIdentity(deviceId: "dev-1")

    let status = controller.statusByMachineId[CodevisorMachine.local.id]
    #expect(status?.cloudDeviceId == "dev-1")
    #expect(status?.supportsScreenSharing == true)
  }
}
