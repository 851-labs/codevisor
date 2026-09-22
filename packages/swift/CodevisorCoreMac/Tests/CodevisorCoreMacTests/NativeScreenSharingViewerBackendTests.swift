import CodevisorClient
import ScreenSharing
import CodevisorTestSupport
import CustomDump
import Foundation
import ScreenSharingTesting
import Testing
@testable import CodevisorCoreMac

/// Signaling order, viewer-id reuse, restart limits, the video watchdog and
/// the stop-after-cancellation rule of the shipped backend, driven through
/// its event stream with scripted signaling and a virtual clock.
@MainActor
struct NativeScreenSharingViewerBackendTests {
  @Test func discoveryReportsDisplaysAndRejectsAnUnavailableHost() async throws {
    let available = NativeBackendHarness()
    let displays = try await available.backend.discover()
    #expect(displays.map(\.id) == ["display"])
    let unavailable = NativeBackendHarness(transport: SharingTransport(capabilitiesStatus: "unavailable"))
    await #expect(throws: (any Error).self) { try await unavailable.backend.discover() }
    #expect(await unavailable.transport.requests.map(\.operation) == [.capabilities])
  }

  @Test func opensThenReportsReadyOnceAfterTheFirstPresentedFrame() async throws {
    let harness = NativeBackendHarness()
    harness.configureSession = { $0.deliversVideo = false }
    harness.connect()
    await harness.clock.waitForSleep(.seconds(8))
    let endpoint = try #require(harness.log.endpoints.first)
    expectNoDifference(harness.log.events, [.opened(endpoint)])
    #expect(harness.sessions[0].offers == 1 && harness.sessions[0].answers == ["fixture answer"])
    harness.surfaces[0].present()
    await awaitObserved { harness.log.events.count >= 2 }
    expectNoDifference(harness.log.events, [.opened(endpoint), .ready])
    await harness.cancelConsumers()
    await harness.transport.stopped.wait()
    #expect(harness.sessions[0].closed && harness.surfaces[0].stopped)
    #expect(harness.clock.pendingCount == 0)
    let operations = await harness.transport.requests.map(\.operation)
    expectNoDifference(operations, [.capabilities, .start, .stop])
  }

  @Test func aPinnedTargetIsNamedOnEveryRequest() async throws {
    let target = "computer-use:0f8fad5b-d9cb-469f-a165-70867728950e"
    let harness = NativeBackendHarness(target: target)
    _ = try await harness.backend.discover()
    harness.connect(target)
    await awaitObserved { harness.log.events.contains(.ready) }
    await harness.clock.waitForSleep(.seconds(8))
    harness.clock.advance(by: .seconds(8))
    await harness.clock.waitForSleep(.seconds(8))
    await harness.cancelConsumers()
    await harness.transport.stopped.wait()
    let requests = await harness.transport.requests
    expectNoDifference(
      requests.map(\.operation), [.capabilities, .capabilities, .start, .heartbeat, .stop])
    #expect(requests.allSatisfy { $0.displayId == target })
  }

  @Test func networkLossAfterVideoReplacesMediaWithinTheSameSession() async throws {
    let harness = NativeBackendHarness()
    harness.connect()
    await awaitObserved { harness.log.events.contains(.ready) }
    harness.sessions[0].onConnectionChanged?("disconnected")
    await awaitObserved { harness.log.events.count >= 5 }
    let endpoints = harness.log.endpoints
    try #require(endpoints.count == 2)
    #expect(endpoints[0] != endpoints[1])
    expectNoDifference(
      harness.log.events, [.opened(endpoints[0]), .ready, .reconnecting, .opened(endpoints[1]), .ready])
    #expect(harness.sessions[0].closed && !harness.sessions[1].closed)
    let requests = await harness.transport.requests
    let start = try #require(requests.first { $0.operation == .start })
    let restart = try #require(requests.first { $0.operation == .restart })
    #expect(start.viewerId == restart.viewerId && start.displayId == restart.displayId)
    #expect(requests.filter { $0.operation == .start }.count == 1)
    #expect(requests.filter { $0.operation == .stop }.isEmpty)
    #expect(requests.filter { $0.operation == .capabilities && $0.viewerId == start.viewerId }.count == 2)
    await harness.cancelConsumers()
    await harness.transport.stopped.wait()
    #expect(harness.sessions.allSatisfy { $0.closed })
    #expect(harness.clock.pendingCount == 0)
  }

  @Test func aHostStopDuringRecoveryEndsTheSessionInsteadOfStartingANewOne() async throws {
    let harness = NativeBackendHarness(transport: SharingTransport(restartStatus: "stopped"))
    harness.connect()
    await awaitObserved { harness.log.events.contains(.ready) }
    harness.sessions[0].onConnectionChanged?("disconnected")
    await awaitObserved { harness.log.finished == 1 }
    #expect(harness.log.events.last == .ended("This Mac cannot start screen sharing right now."))
    let requests = await harness.transport.requests
    #expect(requests.filter { $0.operation == .start }.count == 1)
    #expect(requests.filter { $0.operation == .restart }.count == 1)
    #expect(requests.last?.operation == .stop)
    #expect(harness.sessions.allSatisfy { $0.closed })
  }

  @Test func transportLossBeforeVideoEndsWithoutARestart() async throws {
    let harness = NativeBackendHarness()
    harness.configureSession = { $0.deliversVideo = false }
    harness.connect()
    await harness.clock.waitForSleep(.seconds(8))
    harness.sessions[0].onConnectionChanged?("failed")
    await awaitObserved { harness.log.finished == 1 }
    #expect(harness.log.events.last == .ended("The screen-sharing connection ended. Reconnect to continue."))
    #expect(await harness.transport.requests.filter { $0.operation == .restart }.isEmpty)
    #expect(harness.sessions.count == 1 && harness.sessions[0].closed)
  }

  @Test func cancellingDuringABlockedStartStopsBeforeTheNextStart() async throws {
    let harness = NativeBackendHarness(transport: SharingTransport(blockFirstStart: true))
    let first = harness.connect()
    await harness.transport.started.wait()
    #expect(harness.log.endpoints.count == 1)
    first.cancel()
    await first.value
    harness.connect()
    harness.transport.releaseFirstStart.signal()
    await awaitObserved { harness.log.events.contains(.ready) }
    harness.surfaces[0].present()  // the cancelled attempt's surface: never a second ready
    #expect(harness.log.events.filter { $0 == .ready }.count == 1)
    let requests = await harness.transport.requests
    let starts = requests.filter { $0.operation == .start }
    #expect(starts.count == 2 && starts[0].viewerId != starts[1].viewerId)
    let oldStop = try #require(requests.firstIndex { $0.operation == .stop && $0.viewerId == starts[0].viewerId })
    let newStart = try #require(requests.firstIndex { $0.operation == .start && $0.viewerId == starts[1].viewerId })
    #expect(oldStop < newStart)
    #expect(await harness.transport.stopWasCancelled == false)
    #expect(harness.sessions[0].closed && !harness.sessions[1].closed)
    await harness.cancelConsumers()
    await harness.transport.stopped.wait(for: 2)
    #expect(harness.sessions.allSatisfy { $0.closed })
    #expect(harness.clock.pendingCount == 0)
  }

  @Test func hostStopEndsViewingAtTheHeartbeatBoundary() async throws {
    let harness = NativeBackendHarness(transport: SharingTransport(heartbeatStatus: "stopped"))
    harness.connect()
    await awaitObserved { harness.log.events.contains(.ready) }
    await harness.clock.waitForSleep(.seconds(8))
    harness.clock.advance(by: .seconds(7))
    #expect(await harness.transport.requests.filter { $0.operation == .heartbeat }.isEmpty)
    harness.clock.advance(by: .seconds(1))
    await awaitObserved { harness.log.finished == 1 }
    #expect(harness.log.events.last == .ended("Screen sharing ended on the host Mac."))
    #expect(await harness.transport.requests.map(\.operation) == [.capabilities, .start, .heartbeat, .stop])
    #expect(harness.sessions[0].closed && harness.surfaces[0].stopped)
    #expect(harness.clock.pendingCount == 0)
  }

  @Test func missingVideoTimesOutAndALateFirstFrameCannotReviveTheConnection() async throws {
    let harness = NativeBackendHarness()
    harness.configureSession = { $0.deliversVideo = false }
    harness.connect()
    for heartbeat in 1...2 {
      await harness.clock.waitForSleep(.seconds(8), count: heartbeat)
      harness.clock.advance(by: .seconds(8))
    }
    await harness.clock.waitForSleep(.seconds(8), count: 3)
    #expect(harness.log.finished == 0)
    harness.clock.advance(by: .seconds(7))
    #expect(harness.log.finished == 0)
    harness.clock.advance(by: .seconds(1))
    await awaitObserved { harness.log.finished == 1 }
    #expect(
      harness.log.events.last
        == .ended("No video arrived. Check the connection between these Macs or the configured relay, then retry."))
    harness.surfaces[0].present()
    #expect(!harness.log.events.contains(.ready))
    #expect(harness.sessions[0].closed)
    #expect(harness.clock.pendingCount == 0)
  }

  @Test func decoderFailureEndsViewingAtTheNextHeartbeat() async throws {
    let harness = NativeBackendHarness()
    harness.connect()
    await awaitObserved { harness.log.events.contains(.ready) }
    await harness.clock.waitForSleep(.seconds(8))
    harness.sessions[0].failure = "Fixture hardware decoder failed"
    harness.clock.advance(by: .seconds(8))
    await awaitObserved { harness.log.finished == 1 }
    #expect(harness.log.events.last == .ended("Fixture hardware decoder failed"))
    #expect(harness.sessions[0].closed)
  }

  /// A machine whose capabilities name the VNC provider: the display is
  /// opened through the socket route, no WebRTC session or start request.
  @Test func aVNCProviderIsViewedOverTheSocketRouteWithoutSignaling() async throws {
    let server = try await RFBLoopbackServer(configuration: .init())
    defer { server.stop() }
    let port = server.port
    let opened = OpenedDisplays()
    let harness = NativeBackendHarness(
      transport: SharingTransport(provider: "vnc"),
      vncOpen: { display in
        await opened.append(display)
        return try await VNCConnection.open(host: "127.0.0.1", port: port, password: "secret")
      })
    _ = try await harness.backend.discover()
    harness.connect("vnc:5901")
    #expect(await awaitPolled { harness.log.endpoints.count == 1 })
    #expect(await opened.displays == ["vnc:5901"])
    #expect(harness.sessions.isEmpty)
    harness.surfaces[0].present()
    #expect(await awaitPolled { harness.log.events.count == 2 })
    expectNoDifference(harness.log.events, [.opened(harness.log.endpoints[0]), .ready])
    await harness.cancelConsumers()
    #expect(harness.log.finished == 1)
    #expect(await harness.transport.requests.map(\.operation) == [.capabilities])
  }
}

actor OpenedDisplays {
  private(set) var displays: [String] = []
  func append(_ display: String) { displays.append(display) }
}
