import AppKit
import CodevisorCore
import CodevisorTestSupport
import Foundation
import Observation
import ScreenSharing
import ScreenSharingConnection
import ScreenSharingConnectionTesting
import ScreenSharingV2

@testable import CodevisorCoreMac

@MainActor
@Observable
final class ScreenSharingConnectionsFixture {
  static let machineId = "croissant"
  static let appName = "Alexandru's MacBook Pro"

  var machineIds: Set<String> = [machineId]
  var readyMachineIds: Set<String> = [machineId]
  @ObservationIgnored var workspaces: [Workspace] = []
  @ObservationIgnored var signerFails = false
  @ObservationIgnored var audioSession: FakeMediaSession?
  @ObservationIgnored var openVNC: ScreenSharingConnectionsSource.OpenVNC = { _, _ in
    throw RFBError.transport("This test has no VNC machine.")
  }
  @ObservationIgnored let host: FakeHost
  @ObservationIgnored let media = FakeMedia()
  @ObservationIgnored let signer = FakeSigner()
  @ObservationIgnored let clock = TestClock()
  @ObservationIgnored let wakeCenter = NotificationCenter()
  @ObservationIgnored private(set) lazy var connections = ScreenSharingConnections(
    source: source, clock: ScreenSharingConnectionClock(clock), wakeCenter: wakeCenter)
  @ObservationIgnored private var surfaces: [ScreenSharingSurface] = []
  @ObservationIgnored private var startedSessions = 0

  init(host: FakeHost = FakeHost()) {
    self.host = host
  }

  var connection: ScreenSharingConnection {
    get throws { try connections.connection(for: Self.machineId) }
  }

  @discardableResult
  func show(_ kind: ScreenSharingSurfaceKind = .tab) throws -> ScreenSharingSurface {
    let surface = try connection.attach(kind)
    surfaces.append(surface)
    surface.setOnScreen(true)
    return surface
  }

  func surface(_ role: ScreenSharingViewerRole, inWorkspace workspaceId: UUID? = nil) -> RecordedSurface {
    RecordedSurface(connections.surface(onMachine: Self.machineId, role: role, inWorkspace: workspaceId))
  }

  func goLive() async throws {
    let index = startedSessions
    startedSessions += 1
    await awaitObserved { media.sessions.count > index && media.sessions[index].tokens.count == 1 }
    media.sessions[index].host.deliverFrame(identity: 1)
    await settle(.live)
  }

  func settle(_ state: ScreenSharingConnectionState) async {
    await awaitObserved { (try? connection.state) == state }
  }

  func wake() {
    wakeCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
  }

  static func workspace(on machineId: String = machineId, archived: Bool = false, synced: Bool = true) -> Workspace {
    Workspace(
      name: "Chat", rootDirectory: nil, serverId: machineId, projectId: UUID(),
      centerTree: .leaf(.centerInitial(sessionId: UUID())), isArchived: archived, isServerSynced: synced)
  }

  private var source: ScreenSharingConnectionsSource {
    ScreenSharingConnectionsSource(
      machineIds: { [unowned self] in self.machineIds },
      isReady: { [unowned self] in self.readyMachineIds.contains($0) },
      channel: { [host] _ in host },
      openVNC: { [unowned self] in try await self.openVNC($0, $1) },
      workspaces: { [unowned self] in self.workspaces },
      signer: { [unowned self] in try self.signerOrFailure() },
      connector: { [unowned self] in self.connector },
      makeSurface: { _ in FakeSurface() },
      appName: { Self.appName })
  }

  private var connector: ScreenSharingV2Connector {
    guard let audioSession else { return media.connector }

    return ScreenSharingV2Connector(address: { FakeMedia.address }, connect: { _ in audioSession })
  }

  private func signerOrFailure() throws -> ScreenSharingStartSigner {
    if signerFails { throw FakeSigner.Failure() }
    return signer.signer
  }
}
