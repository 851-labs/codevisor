import CodevisorClient
import CodevisorTestSupport
import ComposableArchitecture
import Foundation
import ScreenSharing
import ScreenSharingConnection
import ScreenSharingConnectionTesting
import ScreenSharingTesting
import Testing

@testable import CodevisorCoreMac

@MainActor
@Suite("Mac surfaces on a machine's screen share connection", .timeLimit(.minutes(1)))
struct ScreenSharingDesktopSurfaceTests {
  private typealias Fixture = ScreenSharingConnectionsFixture
  private static let virtual = ServerScreenSharingDisplay(
    id: "0A000000-0000-4000-8000-0000000000FF", name: "Codevisor Screen Sharing", width: 3840, height: 2160)
  private static let busy = FakeHost.Answer.reply(
    status: "busy", message: "This Mac is already sharing with another viewer.")

  @Test("A window opened after the host swapped its display joins the preview's connection and sends no start")
  func joinsTheLiveConnectionWhateverTheHostListsNow() async throws {
    let fixture = Fixture(host: .old())
    fixture.workspaces = [Fixture.workspace()]
    let preview = fixture.surface(.watcher)
    preview.show()
    try await fixture.goLive()
    await awaitObserved { preview.snapshot.picture != .none }
    fixture.host.displays = [Self.virtual]
    fixture.host.answerEvery(.start, Self.busy)

    let window = fixture.surface(.window)
    window.surface.openedByUser()
    window.show()

    await awaitObserved { window.snapshot.endpoint != nil }
    #expect(window.snapshot.connection == .live && preview.snapshot.mirror == window.snapshot.endpoint)
    #expect(fixture.host.starts.map(\.displayId) == [FakeHost.display.id])
    #expect(window.snapshot.displayId == FakeHost.display.id, "both show what the connection shares")
  }

  @Test("The picture moves to the surface that takes it, and every surface sees who has it at once")
  func movesThePictureBetweenSurfaces() async throws {
    let fixture = Fixture()
    let (tab, window) = (fixture.surface(.tab), fixture.surface(.window))
    tab.show()
    window.show()
    try await fixture.goLive()
    await awaitObserved { window.snapshot.endpoint != nil && tab.snapshot.mirror != nil }

    tab.surface.takePicture()
    #expect(tab.snapshot.endpoint != nil, "both learn it in the same turn, so the video view has one owner")
    #expect(window.snapshot.mirror == tab.snapshot.endpoint)

    tab.surface.detach()
    #expect(window.snapshot.endpoint != nil)
  }

  @Test("Sound plays only while a tab or window is on screen, never for a preview alone")
  func playsSoundOnlyForAFullSurface() async throws {
    let fixture = Fixture()
    let session = FakeMediaSession()
    session.supportsAudio = true
    fixture.audioSession = session
    let (preview, tab) = (fixture.surface(.watcher), fixture.surface(.tab))
    preview.show()
    await awaitObserved { preview.snapshot.picture != .none }
    let audio = try #require(preview.snapshot.mirror?.audio)
    audio.apply(.init(enabled: true, volume: 1))
    #expect(!audio.audible && session.audioRequests.last == false)

    tab.show()
    #expect(audio.audible && session.audioRequests.last == true)
    tab.hide()
    #expect(!audio.audible && session.audioRequests.last == false)
  }

  @Test("Only a surface the user opened starts as an open", arguments: [true, false])
  func sendsOpenOnlyForAnOpenedSurface(opened: Bool) async throws {
    let fixture = Fixture()
    let window = fixture.surface(.window)
    if opened { window.surface.openedByUser() }
    window.show()
    try await fixture.goLive()

    #expect(fixture.host.starts.map(\.intent) == [opened ? .open : .attach])
  }

  @Test("The surface that starts the connection asks for its pane's display; one that joins changes nothing")
  func asksForThePanesDisplayOnlyWhenItStartsTheConnection() async throws {
    let fixture = Fixture()
    fixture.host.displays = [FakeHost.display, FakeHost.second]
    let (first, joiner) = (fixture.surface(.tab), fixture.surface(.tab))
    first.show(preferringDisplay: FakeHost.second.id)
    try await fixture.goLive()

    joiner.show(preferringDisplay: FakeHost.display.id)
    await awaitObserved { joiner.snapshot.connection == .live }

    #expect(fixture.host.starts.map(\.displayId) == [FakeHost.second.id])
    #expect(joiner.snapshot.displayId == FakeHost.second.id)
  }

  @Test("A surface whose machine went away attaches again, and reconnects, when the machine is back")
  func attachesAgainWhenTheMachineReturns() async throws {
    let fixture = Fixture()
    let tab = fixture.surface(.tab)
    tab.show()
    try await fixture.goLive()

    fixture.machineIds = []
    await awaitObserved { tab.snapshot.connection == .off && tab.snapshot.picture == .none }
    fixture.machineIds = [Fixture.machineId]
    try await fixture.goLive()

    await awaitObserved { tab.snapshot.connection == .live }
    #expect(fixture.host.starts.count == 2)
  }

  @Test("An old host is given the workspace of the surface that is on screen")
  func givesAnOldHostTheShownSurfacesWorkspace() async throws {
    let fixture = Fixture(host: .old())
    let (other, shown) = (Fixture.workspace(), Fixture.workspace())
    fixture.workspaces = [other, shown]
    fixture.surface(.tab, inWorkspace: shown.id).show()
    try await fixture.goLive()

    #expect(fixture.host.starts.map(\.workspaceId) == [shown.id])
  }

  @Test("A key that can't be read shows as a failure, and Retry tries again")
  func showsAnUnreadableKeyAsAFailure() async throws {
    let fixture = Fixture()
    fixture.signerFails = true
    let tab = fixture.surface(.tab)
    tab.show()
    #expect(tab.snapshot.connection == .failed(.unclassified(message: FakeSigner.Failure().localizedDescription)))

    fixture.signerFails = false
    tab.surface.retry()
    try await fixture.goLive()
    await awaitObserved { tab.snapshot.connection == .live }
  }

  @Test("A VNC machine is opened through its own socket, and its picture scales the desktop through the server")
  func viewsAVNCMachine() async throws {
    let server = try await RFBLoopbackServer()
    defer { server.stop() }
    let port = server.port
    let display = ServerScreenSharingDisplay(id: "vnc:5901", name: "Desktop", width: 64, height: 48)
    let fixture = Fixture(host: .old())
    fixture.host.provider = "vnc"
    fixture.host.displays = [display]
    let opened = LockIsolated<[String]>([])
    fixture.openVNC = { machineId, displayId in
      opened.withValue { $0 += [machineId, displayId] }
      return try await VNCConnection.open(host: "127.0.0.1", port: port, password: "secret")
    }
    let tab = fixture.surface(.tab)
    tab.show()
    await awaitObserved { tab.snapshot.endpoint != nil }
    server.enqueue([.raw(RFBRectangle(x: 0, y: 0, width: 64, height: 48))])
    await awaitObserved { tab.snapshot.connection == .live }

    let endpoint = try #require(tab.snapshot.endpoint)
    await endpoint.setDesktopScale?(2)

    #expect(opened.value == [Fixture.machineId, display.id])
    #expect(!endpoint.dropsInjectedInput && tab.snapshot.displayId == display.id)
    let scale = try #require(fixture.host.requests(.setScale).first)
    #expect(scale.scale == 2 && scale.displayId == display.id)
    #expect(fixture.host.starts.isEmpty)
  }
}
