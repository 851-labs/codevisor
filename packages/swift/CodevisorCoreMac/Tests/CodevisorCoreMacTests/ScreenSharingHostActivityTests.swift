import Foundation
import Testing

@testable import CodevisorCoreMac

@MainActor
final class ScreenSharingHostActivityLog {
  enum Event: Equatable { case began, ended }

  private(set) var events: [Event] = []
  private(set) lazy var activity = ScreenSharingHostActivity(
    begin: { [weak self] in
      self?.events.append(.began)
      return NSObject()
    },
    end: { [weak self] _ in self?.events.append(.ended) })
}

@MainActor
@Suite("Screen sharing host activity: held from the first hosted session to the last")
struct ScreenSharingHostActivityTests {
  typealias Log = ScreenSharingHostActivityLog

  @Test func oneActivitySpansEveryHostFromTheFirstSessionToTheLast() {
    let log = Log()
    let desktop = log.activity.claim()
    let simulators = log.activity.claim()
    #expect(log.events.isEmpty)

    desktop.isHosting = true
    simulators.isHosting = true
    #expect(log.events == [.began])

    desktop.isHosting = false
    #expect(log.events == [.began])
    simulators.isHosting = false
    #expect(log.events == [.began, .ended])

    simulators.isHosting = true
    #expect(log.events == [.began, .ended, .began])
  }

  @Test func aHostThatGoesAwayWhileHostingGivesTheActivityBack() {
    let log = Log()
    var host: ScreenSharingHostActivity.Claim? = log.activity.claim()
    host?.isHosting = true
    #expect(log.events == [.began])

    host = nil
    #expect(log.events == [.began, .ended])
  }

  @Test func theDesktopHostHoldsItFromStartUntilTheSessionHasEnded() async throws {
    try await ScreenSharingHostOwnershipFixture.run { mac in
      #expect(await mac.capabilities(as: .macBook).status == "available")
      #expect(mac.hosting.events.isEmpty)

      let start = mac.start(as: .macBook, .open)
      #expect(await mac.send(start).status == "connecting")
      #expect(mac.hosting.events == [.began])

      #expect(await mac.send(mac.following(start, .stop)).status == "stopped")
      #expect(mac.host.current == nil && mac.hosting.events == [.began, .ended])
    }
  }

  @Test func theSimulatorHostHoldsItFromItsFirstViewerToItsLast() async throws {
    let world = SimulatorStreamHostWorld()
    let host = world.host()
    #expect(await host.handle(world.request(.capabilities)).status == "available")
    #expect(world.hosting.events.isEmpty)

    let first = try await world.started(as: .macBook, on: host)
    let second = try await world.started(as: .iPhone, on: host)
    #expect(host.sessionCount == 2 && world.hosting.events == [.began])

    #expect(await host.handle(world.following(first, .stop)).status == "stopped")
    #expect(world.hosting.events == [.began])
    world.clock += SimulatorStreamHost.lifetime
    #expect(await host.handle(world.following(second, .heartbeat)).status == "stopped")
    #expect(host.sessionCount == 0 && world.hosting.events == [.began, .ended])
  }

  @Test func theComputerUseHostHoldsItFromItsFirstViewerUntilTheAgentStopsControlling() async throws {
    let world = ComputerUseLivePreviewHostWorld()
    world.activityState = .active
    let host = world.host()
    #expect(world.hosting.events.isEmpty)

    _ = try await world.started(as: .macBook, on: host)
    _ = try await world.started(as: .iPhone, on: host)
    #expect(host.sessionCount == 2 && world.hosting.events == [.began])

    world.activityState = .idle
    host.activityChanged()
    #expect(host.sessionCount == 0 && world.hosting.events == [.began, .ended])
  }
}
