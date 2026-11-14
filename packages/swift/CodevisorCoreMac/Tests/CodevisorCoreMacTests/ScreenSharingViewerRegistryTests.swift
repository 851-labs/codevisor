import CodevisorTestSupport
import CustomDump
import Foundation
import ScreenSharing
import Testing
@testable import CodevisorCoreMac

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ScreenSharingViewerRegistryTests {
  private let registry = ScreenSharingViewerRegistry()
  private let session = FakeMediaSession()
  private let surface = FakeSurface()

  private func endpoint(sound: Bool = true) -> ScreenSharingViewerEndpoint {
    ScreenSharingViewerEndpoint(session: session, surface: surface, sound: sound)
  }

  @Test func panesShowingTheSameDesktopShareTheFirstPanesConnection() async {
    let first = RegistryPane(registry)
    let second = RegistryPane(registry)
    let otherMachine = RegistryPane(registry, machine: "laptop")
    first.show()
    second.show(visible: false)
    otherMachine.show()
    await first.runner.connected.wait()
    await otherMachine.runner.connected.wait()
    await awaitObserved { second.log.events == [.elsewhere(nil)] }
    #expect(first.runner.displays == ["display"] && second.runner.displays.isEmpty)
  }

  @Test func showingAnotherPaneMovesTheLiveViewAfterReleasingControl() async throws {
    let first = RegistryPane(registry)
    let second = RegistryPane(registry)
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
    let sponsor = RegistryPane(registry)
    let viewer = RegistryPane(registry)
    sponsor.show()
    viewer.show(visible: false)
    await sponsor.runner.connected.wait()
    sponsor.runner.send(.opened(endpoint()))
    await sponsor.leave()
    await awaitObserved { viewer.log.events.contains { if case .opened = $0 { true } else { false } } }
    #expect(sponsor.runner.terminated.value == 0 && viewer.runner.displays.isEmpty)

    sponsor.share.retire()

    await viewer.runner.connected.wait()
    #expect(sponsor.runner.terminated.value == 1 && sponsor.runner.idling.value == 1)
    await awaitObserved { viewer.log.events.last == .reconnecting }
  }

  @Test func theLastPaneLeavingStopsTheConnectionBeforeANewOneStarts() async {
    let first = RegistryPane(registry)
    first.runner.holdsStop = true
    first.show()
    await first.runner.connected.wait()
    await first.leave()
    await first.runner.terminated.wait()
    await first.runner.idling.wait()

    let next = RegistryPane(registry)
    next.show()
    #expect(next.runner.displays.isEmpty)
    first.runner.stopFinished.signal()
    await next.runner.connected.wait()
  }

  @Test func aWatcherMirrorsTheLiveEndpointWithoutEverTakingIt() async {
    let tab = RegistryPane(registry)
    let watcher = RegistryPane(registry, role: .watcher)
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

  @Test func theStreamPlaysSoundOnlyWhileAPaneOtherThanAWatcherShowsIt() async throws {
    session.supportsAudio = true
    let watcher = RegistryPane(registry, role: .watcher)
    let tab = RegistryPane(registry)
    watcher.show()
    await watcher.runner.connected.wait()
    let endpoint = endpoint(sound: false)
    watcher.runner.send(.opened(endpoint))
    await awaitObserved { watcher.log.events == [.elsewhere(nil), .elsewhere(endpoint)] }
    let audio = try #require(endpoint.audio)
    #expect(!session.audioRequests.contains(true))

    tab.show()
    audio.apply(.init(enabled: true, volume: 1))
    #expect(session.audioRequests.last == true)

    await tab.leave()
    await awaitObserved { !audio.audible }
    #expect(session.audioRequests.last == false && audio.enabled)
  }

  @Test func aDesktopWindowKeepsTheStreamOverATabUntilItCloses() async {
    let tab = RegistryPane(registry)
    let window = RegistryPane(registry, role: .window)
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
    let watcher = RegistryPane(registry, role: .watcher)
    let otherMachine = RegistryPane(registry, machine: "laptop")
    let window = RegistryPane(registry, role: .window)
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
    var late = RegistryPane(registry, role: .watcher).share.liveStreams().makeAsyncIterator()
    #expect(await late.next() != nil)
  }

  @Test func aPaneThatFoundAnotherDisplayJoinsTheMachinesOneConnection() async {
    let preview = RegistryPane(registry, role: .watcher)
    let tab = RegistryPane(registry)
    let window = RegistryPane(registry, role: .window)
    preview.show("stand-in")
    await preview.runner.connected.wait()
    let endpoint = endpoint()
    preview.runner.send(.opened(endpoint))
    await awaitObserved { preview.log.events == [.elsewhere(nil), .elsewhere(endpoint)] }

    tab.show("virtual", visible: false)
    window.show("virtual")

    await awaitObserved { window.log.events == [.opened(endpoint)] && tab.log.events.count == 2 }
    expectNoDifference(tab.log.events, [.opened(endpoint), .elsewhere(endpoint)])
    expectNoDifference(preview.log.events, [.elsewhere(nil), .elsewhere(endpoint)])
    #expect(preview.runner.displays == ["stand-in"] && tab.runner.displays.isEmpty && window.runner.displays.isEmpty)
  }

  @Test func choosingAnotherDisplayMovesTheMachinesConnectionForEveryPane() async {
    let preview = RegistryPane(registry, role: .watcher)
    let window = RegistryPane(registry, role: .window)
    preview.show()
    await preview.runner.connected.wait()
    let first = endpoint()
    preview.runner.send(.opened(first))
    window.show()
    await awaitObserved { window.log.events == [.opened(first)] }

    window.show("second", switching: true)

    await preview.runner.connected.wait(for: 2)
    #expect(preview.runner.idling.value == 1 && window.runner.displays.isEmpty)
    expectNoDifference(preview.runner.displays, ["display", "second"])
    let second = endpoint()
    preview.runner.send(.opened(second))
    await awaitObserved { window.log.events.last == .opened(second) && preview.log.events.last == .elsewhere(second) }
    expectNoDifference(preview.log.events, [.elsewhere(nil), .elsewhere(first), .reconnecting, .elsewhere(second)])
  }

  @Test func aHostEndEndsEveryPanesStream() async {
    let first = RegistryPane(registry)
    let second = RegistryPane(registry)
    first.show()
    second.show(visible: false)
    await first.runner.connected.wait()
    first.runner.send(.ended("Screen sharing ended on the host Mac."))
    first.runner.finish()
    await awaitObserved { first.log.finished == 1 && second.log.finished == 1 }
    #expect(second.log.events.last == .ended("Screen sharing ended on the host Mac."))
  }
}
