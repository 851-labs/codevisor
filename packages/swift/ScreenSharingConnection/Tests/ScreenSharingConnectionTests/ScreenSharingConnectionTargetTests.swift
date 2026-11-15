import CodevisorClient
import CodevisorTestSupport
import Foundation
import ScreenSharingConnection
import ScreenSharingConnectionTesting
import Testing

@MainActor
@Suite("Screen share connection: fixed targets such as a simulator or a live preview", .timeLimit(.minutes(1)))
struct ScreenSharingConnectionTargetTests {
  nonisolated private static let simulator = "simulator:0B000000-0000-4000-8000-000000000001"
  nonisolated private static let preview = "computer-use:0C000000-0000-4000-8000-000000000001"
  nonisolated private static let notControlling = "The agent is not controlling an app right now."

  private func harness(_ target: String?, oldHost: Bool = false) -> ConnectionHarness {
    let harness = ConnectionHarness(host: oldHost ? .old() : FakeHost())
    harness.target = target
    harness.attachedPane = ScreenSharingLegacyIdentity(workspaceId: UUID(), paneId: UUID())
    return harness
  }

  @Test(
    "A connection with a target sends it on every request and never picks a display",
    arguments: [false, true])
  func sendsTheTargetOnEveryRequest(oldHost: Bool) async {
    let harness = harness(Self.simulator, oldHost: oldHost)
    harness.host.displays = []
    harness.connection.preferredDisplayId = FakeHost.second.id
    harness.show()
    await harness.goLive()
    await harness.beat()
    let sent = harness.host.requests.count
    harness.connection.switchDisplay(to: FakeHost.display.id)
    #expect(harness.connection.state == .live && harness.host.requests.count == sent)

    let connection = harness.connection
    harness.manager.remove(ConnectionHarness.machineId, target: Self.simulator)
    await awaitObserved { harness.host.stops.count == 1 }

    #expect(harness.host.requests.map(\.operation) == [.capabilities, .start, .heartbeat, .stop])
    #expect(harness.host.requests.allSatisfy { $0.displayId == Self.simulator })
    #expect(connection.target == Self.simulator && connection.isEnded)
  }

  @Test("The signed start covers the target, in the frozen message's last line")
  func signsTheTarget() async throws {
    let harness = harness(Self.preview)
    harness.show()
    await harness.goLive()

    let message = try #require(harness.signer.messages.first)
    #expect(
      message.hasPrefix("codevisor.screen-sharing.start.v1\nstart\n") && message.hasSuffix("\nattach\n\(Self.preview)"))
    #expect(harness.host.starts.count == 1, "the host's check of the nonce passed first time")
  }

  @Test("The manager keeps one connection per machine and target, and the machine alone still means its desktop")
  func keepsOneConnectionPerTarget() async {
    let harness = harness(nil)
    let desktop = harness.connection
    harness.target = Self.simulator
    let simulator = harness.connection
    harness.target = Self.preview
    let preview = harness.connection
    harness.target = nil

    #expect(desktop.target == nil && harness.connection === desktop)
    #expect(simulator !== desktop && preview !== desktop && preview !== simulator)
    harness.target = Self.simulator
    #expect(harness.connection === simulator)

    harness.manager.remove(ConnectionHarness.machineId, target: Self.simulator)
    #expect(simulator.isEnded && !desktop.isEnded && !preview.isEnded)
    let fresh = harness.connection
    #expect(fresh !== simulator, "a removed target gets a fresh connection")

    harness.manager.remove(ConnectionHarness.machineId)
    #expect(desktop.isEnded && preview.isEnded && fresh.isEnded)
  }

  enum Recovery: CaseIterable, Sendable { case machineCameOnline, workspaceAppeared }

  @Test("A machine's recovery events reach every one of its connections", arguments: Recovery.allCases)
  func reachesEveryConnectionOfTheMachine(_ recovery: Recovery) async {
    let harness = harness(nil, oldHost: recovery == .workspaceAppeared)
    let (workspaces, pane) = (harness.workspaces, harness.attachedPane)
    let failure: ScreenSharingFailureReason
    switch recovery {
    case .machineCameOnline:
      harness.host.answerEvery(.capabilities, .failure(FakeHost.unreachable))
      failure = .cantReach
    case .workspaceAppeared:
      harness.workspaces = []
      harness.attachedPane = nil
      failure = .noWorkspace
    }
    harness.show()
    let desktop = harness.connection
    await harness.settle(.failed(failure))
    harness.target = Self.simulator
    harness.show()
    let simulator = harness.connection
    await harness.settle(.failed(failure))

    harness.host.answerEvery(.capabilities, nil)
    harness.workspaces = workspaces
    harness.attachedPane = pane
    switch recovery {
    case .machineCameOnline: harness.manager.machineCameOnline(ConnectionHarness.machineId)
    case .workspaceAppeared: harness.manager.workspaceAppeared(ConnectionHarness.machineId)
    }

    #expect(desktop.state == .connecting(.reachingHost) && simulator.state == .connecting(.reachingHost))
  }

  @Test("On an old host a target presents the pane attached right now, registers nothing, and follows a new pane")
  func presentsTheAttachedPaneToAnOldHost() async throws {
    let harness = harness(Self.simulator, oldHost: true)
    let first = try #require(harness.attachedPane)
    let second = ScreenSharingLegacyIdentity(workspaceId: UUID(), paneId: UUID())
    harness.show()
    await harness.goLive()
    await harness.beat()
    #expect(harness.host.requests(.heartbeat).map(\.paneId) == [first.paneId])

    harness.attachedPane = second
    harness.host.answerNext(.heartbeat, .failure(FakeHost.paneGone), .failure(FakeHost.paneGone))
    harness.clock.advance(by: ScreenSharingConnectionDeadlines.heartbeatInterval)
    await harness.settle(.reconnecting)
    await harness.goLive()

    let operations = harness.host.requests.filter { [.start, .stop].contains($0.operation) }
    #expect(operations.map(\.operation) == [.start, .stop, .start])
    #expect(operations.map(\.paneId) == [first.paneId, first.paneId, second.paneId])
    #expect(operations.map(\.workspaceId) == [first.workspaceId, first.workspaceId, second.workspaceId])
    #expect(operations.allSatisfy { $0.app == nil && $0.displayId == Self.simulator })
    #expect(harness.host.registeredPanes.isEmpty)
  }

  @Test("On an old host a target with no pane attached fails as no workspace, without a start")
  func failsWithoutAnAttachedPane() async {
    let harness = harness(Self.simulator, oldHost: true)
    harness.attachedPane = nil
    harness.show()
    await harness.settle(.failed(.noWorkspace))

    #expect(harness.host.starts.isEmpty && harness.host.registeredPanes.isEmpty)
  }

  struct Refusal: Sendable, CustomTestStringConvertible {
    var target: String?
    var oldHost: Bool
    var operation: FakeHost.Operation
    var status: String
    var reason: String?
    var message: String?
    var expected: ScreenSharingFailureReason
    var testDescription: String {
      "\(target == nil ? "desktop" : "target"), \(oldHost ? "old" : "new") host, \(operation) \(status) \(reason ?? "")"
    }
  }

  nonisolated static let refusals = [
    Refusal(
      target: preview, oldHost: true, operation: .capabilities, status: "unavailable", message: notControlling,
      expected: .nothingToView(message: notControlling)),
    Refusal(
      target: simulator, oldHost: true, operation: .capabilities, status: "starting",
      message: "The simulator is starting.", expected: .nothingToView(message: "The simulator is starting.")),
    Refusal(
      target: simulator, oldHost: true, operation: .start, status: "starting",
      expected: .nothingToView(message: nil)),
    Refusal(
      target: preview, oldHost: false, operation: .capabilities, status: "unavailable", reason: "nothing-to-view",
      message: notControlling, expected: .nothingToView(message: notControlling)),
    Refusal(
      target: simulator, oldHost: false, operation: .capabilities, status: "unavailable",
      message: "Install Xcode on this Mac to use its simulators.",
      expected: .unclassified(message: "Install Xcode on this Mac to use its simulators.")),
    Refusal(
      target: preview, oldHost: true, operation: .start, status: "busy",
      message: "Too many viewers are watching this agent.",
      expected: .unclassified(message: "Too many viewers are watching this agent.")),
    Refusal(
      target: nil, oldHost: true, operation: .capabilities, status: "unavailable", message: "No screens.",
      expected: .unclassified(message: "No screens.")),
    Refusal(
      target: nil, oldHost: true, operation: .start, status: "busy", message: "Already sharing.",
      expected: .inUseOldHost),
  ]

  @Test("What a refusal without a reason code means depends on the target and on the host's age", arguments: refusals)
  func classifiesARefusal(_ refusal: Refusal) async {
    let harness = harness(refusal.target, oldHost: refusal.oldHost)
    harness.host.answerEvery(
      refusal.operation, .reply(status: refusal.status, message: refusal.message, reason: refusal.reason))
    harness.show()
    await harness.settle(.failed(refusal.expected))

    #expect(harness.host.starts.count == (refusal.operation == .start ? 1 : 0))
  }

  @Test("When the target appears, a connection that had nothing to view connects again without taking over")
  func connectsWhenTheTargetAppears() async {
    let harness = harness(Self.preview)
    harness.host.answerEvery(
      .capabilities, .reply(status: "unavailable", message: Self.notControlling, reason: "nothing-to-view"))
    let surface = harness.show()
    await harness.settle(.failed(.nothingToView(message: Self.notControlling)))
    let sent = harness.host.requests.count

    surface.setOnScreen(false)
    harness.manager.targetAppeared(ConnectionHarness.machineId, target: Self.preview)
    surface.setOnScreen(true)
    #expect(harness.host.requests.count == sent, "an event that arrives with nothing on screen is not acted on")

    harness.host.answerEvery(.capabilities, nil)
    harness.manager.targetAppeared(ConnectionHarness.machineId, target: Self.simulator)
    #expect(harness.connection.state == .failed(.nothingToView(message: Self.notControlling)))
    harness.manager.targetAppeared(ConnectionHarness.machineId, target: Self.preview)
    #expect(harness.connection.state == .connecting(.reachingHost))
    await harness.goLive()

    #expect(harness.host.starts.map(\.intent) == [.attach])
  }

  @Test("The target appearing does not restart a connection that failed for another reason")
  func leavesOtherFailuresAloneWhenTheTargetAppears() async {
    let harness = harness(Self.simulator)
    harness.host.answerEvery(.capabilities, .reply(status: "unavailable", message: "Install Xcode."))
    harness.show()
    await harness.settle(.failed(.unclassified(message: "Install Xcode.")))
    let sent = harness.host.requests.count

    harness.manager.targetAppeared(ConnectionHarness.machineId, target: Self.simulator)

    #expect(harness.connection.state == .failed(.unclassified(message: "Install Xcode.")))
    #expect(harness.host.requests.count == sent)
  }

  @Test("A connection can heartbeat faster than 8 s, and failed heartbeats still take 25 s to count as a drop")
  func heartbeatsAtItsOwnInterval() async {
    let harness = harness(Self.preview)
    harness.heartbeatInterval = .seconds(3)
    harness.show()
    await harness.goLive()
    harness.host.answerEvery(.heartbeat, .failure(FakeHost.unreachable))

    for _ in 1...8 { await harness.tick() }
    await awaitObserved { harness.host.completed(.heartbeat) == 8 }
    #expect(harness.connection.state == .live, "24 s of failed heartbeats is still inside the limit")

    harness.clock.advance(by: .seconds(3))
    await harness.settle(.reconnecting)
  }
}
