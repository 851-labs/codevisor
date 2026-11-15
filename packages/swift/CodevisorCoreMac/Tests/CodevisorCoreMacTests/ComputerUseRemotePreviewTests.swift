import CodevisorTestSupport
import Foundation
import ScreenSharing
import ScreenSharingConnection
import ScreenSharingConnectionTesting
import Testing

@testable import CodevisorCoreMac

@MainActor
@Suite("Computer Use remote preview on the connection core", .timeLimit(.minutes(1)))
struct ComputerUseRemotePreviewTests {
  typealias Fixture = ScreenSharingConnectionsFixture

  static let session = "0f8fad5b-d9cb-469f-a165-70867728950e"
  static let target = "computer-use:\(session)"
  static let notControlling = "The agent is not controlling an app right now."

  @MainActor
  final class Preview {
    let fixture: Fixture
    let viewer = ComputerUseLivePreviewViewer(title: "", phase: .connecting, onDetach: nil)
    var isActive: Bool? = false
    private(set) var shownSessions: [ObjectIdentifier] = []
    private(set) var activityChecks = 0
    private(set) var preview: ComputerUseRemotePreview!

    init(_ fixture: Fixture = Fixture()) {
      self.fixture = fixture
    }

    var connection: ScreenSharingConnection {
      get throws {
        let connection = fixture.connections.targetConnection(
          onMachine: Fixture.machineId, target: ComputerUseRemotePreviewTests.target, attachedPane: { nil },
          heartbeatInterval: ComputerUseRemotePreviewTiming.heartbeat)
        return try #require(connection)
      }
    }

    func open() throws {
      let connection = try connection
      let clock = fixture.clock
      preview = ComputerUseRemotePreview(
        viewer: viewer,
        dependencies: .init(
          connection: connection, machineName: Fixture.machineId,
          isActive: { [unowned self] in
            activityChecks += 1
            return isActive
          },
          sleep: { try await clock.sleep(for: $0) },
          makeSurface: { [unowned self] session, _ in
            shownSessions.append(ObjectIdentifier(session))
            return nil
          },
          end: { [fixture] in
            fixture.connections.endTargetConnection(
              onMachine: Fixture.machineId, target: ComputerUseRemotePreviewTests.target)
          }))
    }

    func goLive(session index: Int = 0) async {
      let media = fixture.media
      await awaitObserved { media.sessions.count > index && media.sessions[index].tokens.count == 1 }
      media.sessions[index].host.deliverFrame(identity: 1)
      await awaitObserved { viewer.phase == .live }
    }
  }

  @Test("The preview goes live on its own connection, titled with the app's name, and shows the session's video")
  func goesLive() async throws {
    let preview = Preview()
    try preview.open()

    await preview.goLive()

    #expect(preview.viewer.title == FakeHost.display.name)
    #expect(preview.shownSessions.count == 1)
    #expect(try preview.connection !== preview.fixture.connection)
    #expect(preview.fixture.host.starts.first?.app != nil)
  }

  @Test("Every request names the chat, and heartbeats go every 2 s so a hidden window is noticed quickly")
  func namesTheTargetAndBeatsEveryTwoSeconds() async throws {
    let preview = Preview()
    try preview.open()
    await preview.goLive()
    let host = preview.fixture.host

    for beat in 1...2 {
      await preview.fixture.clock.waitForSleep(ComputerUseRemotePreviewTiming.heartbeat, count: beat)
      preview.fixture.clock.advance(by: ComputerUseRemotePreviewTiming.heartbeat)
      await awaitObserved { host.completed(.heartbeat) == beat }
    }

    #expect(host.requests.map(\.operation) == [.capabilities, .start, .heartbeat, .heartbeat])
    #expect(host.requests.allSatisfy { $0.displayId == Self.target })
  }

  @Test("The host's notice reaches the preview, and clears when the window shows again")
  func showsTheHostsNotice() async throws {
    let preview = Preview()
    try preview.open()
    await preview.goLive()
    let (host, clock) = (preview.fixture.host, preview.fixture.clock)

    host.answerNext(.heartbeat, .reply(status: "viewing", message: "TextEdit is hidden"), .reply(status: "viewing"))
    await clock.waitForSleep(ComputerUseRemotePreviewTiming.heartbeat)
    clock.advance(by: ComputerUseRemotePreviewTiming.heartbeat)
    await awaitObserved { preview.viewer.notice == "TextEdit is hidden" }

    await clock.waitForSleep(ComputerUseRemotePreviewTiming.heartbeat, count: 2)
    clock.advance(by: ComputerUseRemotePreviewTiming.heartbeat)
    await awaitObserved { preview.viewer.notice == nil }
  }

  @Test("With nothing to view the preview waits, asks only whether there is something, and connects when there is")
  func waitsForSomethingToView() async throws {
    let preview = Preview()
    let host = preview.fixture.host
    host.answerEvery(
      .capabilities, .reply(status: "unavailable", message: Self.notControlling, reason: "nothing-to-view"))
    try preview.open()
    await awaitObserved { preview.viewer.phase == .searching }

    let quiet = ComputerUseRemotePreviewTiming.quietPoll
    await preview.fixture.clock.waitForSleep(quiet)
    preview.fixture.clock.advance(by: quiet)
    await preview.fixture.clock.waitForSleep(quiet, count: 2)
    #expect(preview.activityChecks == 1 && host.requests.count == 1)

    host.answerEvery(.capabilities, nil)
    preview.isActive = true
    preview.fixture.clock.advance(by: quiet)
    await preview.goLive()

    #expect(host.requests(.capabilities).count == 2 && host.starts.count == 1)
  }

  @Test("A preview that couldn't reach the host is tried again once the host says there is something to view")
  func retriesCantReachWhenThereIsSomethingToView() async throws {
    let preview = Preview()
    let host = preview.fixture.host
    host.answerEvery(.capabilities, .failure(FakeHost.unreachable))
    try preview.open()
    let sentence = ScreenSharingFailureReason.cantReach.sentence(on: Fixture.machineId)
    await awaitObserved { preview.viewer.phase == .stopped(sentence) }

    host.answerEvery(.capabilities, nil)
    preview.isActive = true
    let quiet = ComputerUseRemotePreviewTiming.quietPoll
    await preview.fixture.clock.waitForSleep(quiet)
    preview.fixture.clock.advance(by: quiet)
    await preview.goLive()

    #expect(preview.activityChecks == 1 && host.starts.count == 1)
  }

  @Test(
    "Only nothing to view and can't reach are worth asking about again; any other failure waits for the user",
    arguments: [
      (ScreenSharingConnectionState.failed(.nothingToView(message: nil)), true),
      (.failed(.cantReach), true),
      (.failed(.unclassified(message: "Too many viewers are watching this agent.")), false),
      (.failed(.permissionMissing), false),
      (.failed(.updateNeeded), false),
      (.failed(.keptDropping), false),
      (.live, false),
      (.connecting(.reachingHost), false),
    ])
  func asksAgainOnlyForPassingFailures(state: ScreenSharingConnectionState, asksAgain: Bool) {
    #expect(ComputerUseRemotePreview.waits(in: state) == asksAgain)
  }

  @Test("A preview let go of without being closed still ends its connection")
  func endsTheConnectionWhenReleased() async throws {
    let fixture = Fixture()
    var preview: Preview? = Preview(fixture)
    try preview?.open()
    let connection = try #require(try preview?.connection)
    await awaitObserved { fixture.host.starts.count == 1 }

    preview = nil

    #expect(connection.isEnded)
  }

  @Test("A refusal shows the host's sentence, such as the viewer limit")
  func showsTheHostsRefusal() async throws {
    let preview = Preview()
    let limit = "Too many viewers are watching this agent."
    preview.fixture.host.answerEvery(.start, .reply(status: "busy", message: limit))
    try preview.open()

    await awaitObserved { preview.viewer.phase == .stopped(limit) }
  }

  @Test("Closing the preview ends its connection at once, but not while another preview of the chat is open")
  func endsTheConnectionWithTheLastPreview() async throws {
    let fixture = Fixture()
    let (first, second) = (Preview(fixture), Preview(fixture))
    try first.open()
    try second.open()
    await first.goLive()
    let connection = try first.connection

    first.preview.detach()
    #expect(!connection.isEnded && fixture.host.stops.isEmpty)

    second.preview.detach()
    #expect(connection.isEnded)
    await awaitObserved { fixture.host.stops.count == 1 }
    #expect(fixture.host.stops.first?.displayId == Self.target)
  }
}
