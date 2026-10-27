import CodevisorTestSupport
import CustomDump
import Foundation
import ScreenSharing
import Testing
@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingViewerRegistryTests {
  @MainActor
  private final class FakeRunner: ScreenSharingViewerConnecting {
    let connected = TestSignal()
    let terminated = TestSignal()
    let idling = TestSignal()
    let stopFinished = TestSignal()
    var holdsStop = false
    private(set) var connects = 0
    private var continuation: AsyncStream<ScreenSharingViewerEvent>.Continuation?

    func connect(_ display: String) -> AsyncStream<ScreenSharingViewerEvent> {
      connects += 1
      let (stream, continuation) = AsyncStream<ScreenSharingViewerEvent>.makeStream()
      self.continuation = continuation
      continuation.onTermination = { [terminated] _ in terminated.signal() }
      connected.signal()
      return stream
    }

    func idle() async {
      idling.signal()
      if holdsStop { await stopFinished.wait() }
    }

    func send(_ event: ScreenSharingViewerEvent) { continuation?.yield(event) }
    func finish() { continuation?.finish() }
  }

  @MainActor
  private final class Pane {
    let runner = FakeRunner()
    let share: ScreenSharingViewerRegistry.Share
    let log = ScreenSharingEventLog()
    private var consumer: Task<Void, Never>?

    init(
      _ registry: ScreenSharingViewerRegistry, machine: String = "studio", role: ScreenSharingViewerRole = .tab
    ) {
      share = registry.share(machineId: machine, paneId: UUID(), role: role, runner: runner)
    }

    func show(visible: Bool = true) {
      share.setVisible(visible)
      let stream = share.connect("display")
      consumer = Task { @MainActor [log] in
        for await event in stream { log.append(event) }
        log.finish()
      }
    }

    func leave() async {
      consumer?.cancel()
      await consumer?.value
    }
  }

  private let registry = ScreenSharingViewerRegistry()
  private let session = FakeMediaSession()
  private let surface = FakeSurface()

  private func endpoint() -> ScreenSharingViewerEndpoint {
    session.surface = surface
    return ScreenSharingViewerEndpoint(session: session, surface: surface)
  }

  @Test func panesShowingTheSameDesktopShareTheFirstPanesConnection() async {
    let first = Pane(registry)
    let second = Pane(registry)
    let otherMachine = Pane(registry, machine: "laptop")
    first.show()
    second.show(visible: false)
    otherMachine.show()
    await first.runner.connected.wait()
    await otherMachine.runner.connected.wait()
    await awaitObserved { second.log.events == [.elsewhere(nil)] }
    #expect(first.runner.connects == 1 && second.runner.connects == 0)
  }

  @Test func showingAnotherPaneMovesTheLiveViewAfterReleasingControl() async throws {
    let first = Pane(registry)
    let second = Pane(registry)
    first.show()
    second.show(visible: false)
    await first.runner.connected.wait()
    let endpoint = endpoint()
    first.runner.send(.opened(endpoint))
    first.runner.send(.ready)
    await awaitObserved { first.log.events.count == 2 }
    session.controlChannel.isAvailable = true
    let lease = UUID()
    #expect(endpoint.beginInput(lease: lease) == nil)

    second.share.setVisible(true)

    #expect(session.controlChannel.sent == [.release(lease: lease)] && !surface.inputActive)
    await awaitObserved { second.log.events.count == 4 && first.log.events.count == 3 }
    expectNoDifference(second.log.events, [.elsewhere(nil), .elsewhere(endpoint), .opened(endpoint), .ready])
    expectNoDifference(first.log.events, [.opened(endpoint), .ready, .elsewhere(endpoint)])
  }

  @Test func hidingTheSponsorKeepsItsConnectionButClosingItReconnectsUnderAnotherPane() async {
    let sponsor = Pane(registry)
    let viewer = Pane(registry)
    sponsor.show()
    viewer.show(visible: false)
    await sponsor.runner.connected.wait()
    sponsor.runner.send(.opened(endpoint()))
    await sponsor.leave()
    await awaitObserved { viewer.log.events.contains { if case .opened = $0 { true } else { false } } }
    #expect(sponsor.runner.terminated.value == 0 && viewer.runner.connects == 0)

    sponsor.share.retire()

    await viewer.runner.connected.wait()
    #expect(sponsor.runner.terminated.value == 1 && sponsor.runner.idling.value == 1)
    await awaitObserved { viewer.log.events.last == .reconnecting }
  }

  @Test func theLastPaneLeavingStopsTheConnectionBeforeANewOneStarts() async {
    let first = Pane(registry)
    first.runner.holdsStop = true
    first.show()
    await first.runner.connected.wait()
    await first.leave()
    await first.runner.terminated.wait()
    await first.runner.idling.wait()

    let next = Pane(registry)
    next.show()
    #expect(next.runner.connects == 0)
    first.runner.stopFinished.signal()
    await next.runner.connected.wait()
  }

  @Test func aWatcherMirrorsTheLiveEndpointWithoutEverTakingIt() async {
    let tab = Pane(registry)
    let watcher = Pane(registry, role: .watcher)
    tab.show(visible: false)
    watcher.show()
    await tab.runner.connected.wait()
    let endpoint = endpoint()
    tab.runner.send(.opened(endpoint))
    await awaitObserved { watcher.log.events == [.elsewhere(nil), .elsewhere(endpoint)] }

    watcher.share.claim()
    watcher.share.setVisible(true)
    tab.share.setVisible(true)

    await awaitObserved { tab.log.events == [.opened(endpoint)] }
    expectNoDifference(watcher.log.events, [.elsewhere(nil), .elsewhere(endpoint)])
  }

  @Test func aDesktopWindowKeepsTheStreamOverATabUntilItCloses() async {
    let tab = Pane(registry)
    let window = Pane(registry, role: .window)
    tab.show()
    await tab.runner.connected.wait()
    let endpoint = endpoint()
    tab.runner.send(.opened(endpoint))
    await awaitObserved { tab.log.events == [.opened(endpoint)] }
    window.show()
    await awaitObserved { window.log.events == [.opened(endpoint)] }

    tab.share.setVisible(false)
    tab.share.setVisible(true)
    #expect(window.log.events == [.opened(endpoint)])

    await window.leave()
    await awaitObserved { tab.log.events.last == .opened(endpoint) }
    expectNoDifference(tab.log.events, [.opened(endpoint), .elsewhere(endpoint), .opened(endpoint)])
  }

  @Test func aPaneWaitingOnAMachineHearsWhenItsDesktopStartsStreaming() async {
    let watcher = Pane(registry, role: .watcher)
    let otherMachine = Pane(registry, machine: "laptop")
    let window = Pane(registry, role: .window)
    let heard = ScreenSharingEventLog()
    let listener = Task { @MainActor in
      for await _ in watcher.share.liveStreams() { heard.append(.ready) }
    }
    otherMachine.show()
    await otherMachine.runner.connected.wait()
    otherMachine.runner.send(.opened(endpoint()))
    await awaitObserved { otherMachine.log.events.count == 1 }
    window.show()
    await window.runner.connected.wait()
    #expect(heard.events.isEmpty)

    window.runner.send(.opened(endpoint()))

    await awaitObserved { heard.events.count == 1 }
    listener.cancel()
    var late = watcher.share.liveStreams().makeAsyncIterator()
    #expect(await late.next() != nil)
  }

  @Test func aHostEndEndsEveryPanesStream() async {
    let first = Pane(registry)
    let second = Pane(registry)
    first.show()
    second.show(visible: false)
    await first.runner.connected.wait()
    first.runner.send(.ended("Screen sharing ended on the host Mac."))
    first.runner.finish()
    await awaitObserved { first.log.finished == 1 && second.log.finished == 1 }
    #expect(second.log.events.last == .ended("Screen sharing ended on the host Mac."))
  }
}
