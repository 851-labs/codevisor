import Foundation
import Testing
import CodevisorTestSupport

@testable import CodevisorCore

@MainActor
@Suite("MachineStatus features")
struct MachineStatusFeaturesTests {
  private func makeController(fake: SyncFakeServerClient) throws -> (MachineController, CodevisorMachine) {
    let remote = accountMachine("remote-a")
    let controller = MachineController(
      store: InMemoryStore(),
      projectList: ProjectListModel.fixture(),
      clientFactory: { machine in
        machine.id == remote.id ? fake : SyncFakeServerClient(projects: [], sessions: [])
      }
    )
    signIn(controller, machines: [remote])
    return (controller, remote)
  }

  @Test("Status probe caches the advertised feature list")
  func probeCachesFeatures() async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureInfoFeatures(["plugins-v2", "screen-sharing-v1"])
    fake.configureInfoMaxUploadBytes(524_288_000)
    let (controller, remote) = try makeController(fake: fake)

    await controller.refreshStatus(for: remote.id)

    let status = try #require(controller.statusByMachineId[remote.id])
    #expect(status.features == ["plugins-v2", "screen-sharing-v1"])
    #expect(status.supportsScreenSharing)
    #expect(status.supportsPlugins)
    #expect(status.uploadLimitBytes == 524_288_000)
  }

  @Test("A server without a feature list advertises no capabilities and the legacy upload limit")
  func missingFeaturesMeansNone() async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureInfoFeatures(nil)
    let (controller, remote) = try makeController(fake: fake)

    await controller.refreshStatus(for: remote.id)

    let status = try #require(controller.statusByMachineId[remote.id])
    #expect(status.features.isEmpty)
    #expect(!status.supportsScreenSharing)
    #expect(status.uploadLimitBytes == 32 * 1024 * 1024)
  }

  @Test("Adopting a cloud identity keeps the probed features")
  func adoptingCloudIdentityKeepsFeatures() {
    let store = InMemoryStore()
    let controller = MachineController(
      store: store,
      projectList: ProjectListModel.fixture(),
      clientFactory: { _ in SyncFakeServerClient(projects: [], sessions: []) }
    )
    controller.connection(for: CodevisorMachine.local.id).status = MachineStatus(
      isReachable: true, label: "Local 1.0.0", serverId: "local",
      features: ["screen-sharing-v1"]
    )

    controller.adoptLocalCloudIdentity(deviceId: "dev-1")

    let status = controller.statusByMachineId[CodevisorMachine.local.id]
    #expect(status?.cloudDeviceId == "dev-1")
    #expect(status?.supportsScreenSharing == true)
  }

  @Test("Only other machines that support screen sharing offer a desktop")
  func desktopSkipsThisMac() async throws {
    let fake = SyncFakeServerClient(projects: [], sessions: [])
    fake.configureInfoFeatures(["screen-sharing-v1"])
    let (controller, remote) = try makeController(fake: fake)
    await controller.refreshStatus(for: remote.id)
    controller.connection(for: CodevisorMachine.local.id).status = MachineStatus(
      isReachable: true, label: "Local 1.0.0", serverId: "local", features: ["screen-sharing-v1"])

    #expect(controller.desktopMachine(for: remote.id)?.id == remote.id)
    #expect(controller.desktopMachine(for: CodevisorMachine.local.id) == nil)
  }
}
