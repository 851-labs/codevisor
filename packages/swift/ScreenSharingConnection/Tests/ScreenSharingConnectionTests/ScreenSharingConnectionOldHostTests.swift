import CodevisorTestSupport
import Foundation
import ScreenSharingConnection
import Testing

@MainActor
@Suite("Screen share connection: hosts without app-owned sessions", .timeLimit(.minutes(1)))
struct ScreenSharingConnectionOldHostTests {
  private static let displayGone = FakeHost.Answer.reply(
    status: "unavailable", message: "The selected display is no longer available.")

  @Test("An old host sees one registered workspace-and-pane identity per machine, across surfaces and reconnects")
  func presentsOnePaneIdentity() async throws {
    let harness = ConnectionHarness(host: .old())
    let identity = harness.legacyIdentity(harness.workspaces[0])
    _ = harness.show(.preview)
    let first = await harness.goLive()
    harness.open(.window)
    first.host.report(connection: "failed")
    await harness.settle(.reconnecting)
    await harness.goLive()
    await harness.stayLive()

    let starts = harness.host.starts
    #expect(harness.host.registeredPanes == [identity])
    #expect(starts.count == 2 && harness.host.requests(.restart).isEmpty)
    #expect(starts.allSatisfy { $0.base.workspaceId == identity.workspaceId && $0.base.paneId == identity.paneId })
    #expect(starts.allSatisfy { $0.app == nil && $0.intent == nil })
    #expect(starts.map(\.base.displayId) == [FakeHost.display.id, FakeHost.display.id])
    #expect(starts[0].base.viewerId != starts[1].base.viewerId)
    let heartbeat = try #require(harness.host.requests(.heartbeat).last)
    #expect(heartbeat.base.paneId == identity.paneId && heartbeat.base.viewerId == starts[1].base.viewerId)
    #expect(harness.connection.display == FakeHost.display)
  }

  @Test("An old host that is busy with another viewer fails as in use, with nothing retried")
  func failsWhenAnOldHostIsBusy() async {
    let harness = ConnectionHarness(host: .old())
    harness.host.answerNext(
      .start, .reply(status: "busy", message: "This Mac is already sharing with another viewer."))
    harness.open(.tab)
    await harness.settle(.failed(.inUseOldHost))

    #expect(harness.host.starts.count == 1 && harness.clock.pendingCount == 0)
  }

  @Test("An old host whose display changed since it was listed is listed again and tried once more")
  func refreshesTheDisplayListOnce() async {
    let harness = ConnectionHarness(host: .old())
    harness.host.onStart = { harness.host.displays = [FakeHost.second] }
    harness.host.answerNext(.start, Self.displayGone)
    _ = harness.show()
    await harness.goLive()

    #expect(harness.host.requests(.capabilities).count == 2)
    #expect(harness.host.starts.map(\.base.displayId) == [FakeHost.display.id, FakeHost.second.id])
    #expect(harness.connection.display == FakeHost.second)
    #expect(harness.host.requests(.stop).isEmpty, "the connection never failed in between")
  }

  @Test("An old host that still has no such display after one refresh fails as no display")
  func failsWhenTheDisplayStaysGone() async {
    let harness = ConnectionHarness(host: .old())
    harness.host.answerEvery(.start, Self.displayGone)
    _ = harness.show()
    await harness.settle(.failed(.noDisplay))

    #expect(harness.host.starts.count == 2)
  }

  @Test("When the workspace behind the pane identity is archived, another live workspace takes over as a reconnect")
  func movesToAnotherWorkspace() async throws {
    let harness = ConnectionHarness(host: .old())
    let other = UUID()
    let (old, new) = (harness.legacyIdentity(harness.workspaces[0]), harness.legacyIdentity(other))
    _ = harness.show()
    await harness.goLive()

    harness.workspaces = [other]
    harness.host.answerNext(.heartbeat, .failure(FakeHost.paneGone), .failure(FakeHost.paneGone))
    harness.clock.advance(by: ScreenSharingConnectionDeadlines.heartbeatInterval)
    await harness.settle(.reconnecting)
    await harness.goLive()

    let operations = harness.host.requests.filter { [.start, .stop].contains($0.base.operation) }
    #expect(harness.host.registeredPanes == [old, new])
    #expect(operations.map(\.base.operation) == [.start, .stop, .start])
    #expect(operations.map(\.base.paneId) == [old.paneId, old.paneId, new.paneId])
    #expect(operations[1].base.viewerId == operations[0].base.viewerId)
  }

  @Test("An old host on a machine with no live workspace fails as needing an update, without a start")
  func failsWithoutALiveWorkspace() async {
    let harness = ConnectionHarness(host: .old())
    harness.workspaces = []
    _ = harness.show()
    await harness.settle(.failed(.updateNeeded))

    #expect(harness.host.starts.isEmpty && harness.host.registeredPanes.isEmpty)
  }

  @Test("An old host that ended the session on purpose is not restarted, and its message is kept")
  func doesNotRestartAnOldHostThatStopped() async {
    let message = "Screen sharing was stopped on the host Mac."
    let harness = ConnectionHarness(host: .old())
    _ = harness.show()
    let session = await harness.goLive()
    harness.host.answerEvery(.heartbeat, .reply(status: "failed", message: message))
    session.host.report(connection: "failed")
    await harness.settle(.failed(.unclassified(message: message)))

    #expect(harness.host.starts.count == 1)
  }
}
