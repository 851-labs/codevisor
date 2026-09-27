import CodevisorTestSupport
import Observation
import Foundation
import Testing
import ACPKit
import CodevisorClient
@testable import CodevisorCloud

@Suite("CloudDirectConnection")
struct CloudDirectConnectionTests {
  @Test("A silent listener times out instead of hanging the opener")
  func helloTimeout() async throws {
    let scripted = ScriptedDirectMachine()
    scripted.acceptsHello = false
    let clock = TestClock()
    let connection = makeDirectConnection(to: scripted, readyTimeout: .seconds(5), clock: clock)
    let ready = Task { try await connection.waitUntilReady() }
    await clock.waitForSleep(.seconds(5))
    clock.advance(by: .seconds(5))
    await #expect(throws: CloudHubConnectionError.timedOut) { try await ready.value }
    await connection.shutdown()
  }

  @Test("Socket death fails channels, fires onDown once, and stays dead")
  func socketDeath() async throws {
    let scripted = ScriptedDirectMachine()
    let downs = Recorder()
    let connection = makeDirectConnection(to: scripted) { downs.record(Data()) }
    let recorder = Recorder()

    _ = try await connection.openChannel(
      channelType: "ws",
      params: nil,
      onMessage: { recorder.record($0) },
      onClosed: { recorder.recordClose($0) }
    )
    scripted.socket.disconnect()

    #expect(await waitUntil { recorder.closes.count == 1 })
    #expect(recorder.closes == [nil])
    #expect(await waitUntil { downs.messages.count == 1 })
    // The pipe is single-shot: no reconnect loop, no second onDown.
    await #expect(throws: CloudHubConnectionError.disconnected) {
      _ = try await connection.openChannel(
        channelType: "ws", params: nil, onMessage: { _ in }, onClosed: { _ in })
    }
    #expect(downs.messages.count == 1)
  }

  @Test("An answered keepalive keeps the pipe up past the pong deadline")
  func answeredKeepaliveKeepsPipeUp() async throws {
    let scripted = ScriptedDirectMachine()
    // The test answers the ping itself, once the pong deadline is armed.
    scripted.respondsToPing = false
    let downs = Recorder()
    let clock = TestClock()
    let connection = makeDirectConnection(
      to: scripted,
      heartbeatInterval: .seconds(10),
      heartbeatTimeout: .seconds(5),
      clock: clock
    ) { downs.record(Data()) }

    try await connection.waitUntilReady()
    await clock.waitForSleep(.seconds(10))
    clock.advance(by: .seconds(10))
    #expect(await waitUntil { scripted.pings == 1 })
    await clock.waitForSleep(.seconds(5))
    scripted.socket.pushJSON(#"{"t":"pong"}"#)
    await scripted.socket.drain()
    await clock.waitForSleep(.seconds(10), count: 2)

    // Past the pong deadline and on to the next heartbeat: an unanswered
    // deadline would take the pipe down and never send the second ping.
    clock.advance(by: .seconds(10))
    #expect(await waitUntil { scripted.pings == 2 || !downs.messages.isEmpty })
    #expect(downs.messages.isEmpty)
    #expect(scripted.pings == 2)
    #expect(await connection.isReady)
    await connection.shutdown()
  }

  @Test("A missed pong deadline tears the pipe down")
  func heartbeatDeadline() async throws {
    let scripted = ScriptedDirectMachine()
    scripted.respondsToPing = false
    let downs = Recorder()
    let clock = TestClock()
    let connection = makeDirectConnection(
      to: scripted,
      heartbeatInterval: .seconds(10),
      heartbeatTimeout: .seconds(5),
      clock: clock
    ) { downs.record(Data()) }

    try await connection.waitUntilReady()
    await clock.waitForSleep(.seconds(10))
    clock.advance(by: .seconds(10))
    await clock.waitForSleep(.seconds(5))
    #expect(downs.messages.isEmpty)
    clock.advance(by: .seconds(5))
    #expect(await waitUntil { downs.messages.count == 1 })
    #expect(scripted.pings >= 1)
  }

  @Test("An unanswered open demotes the pipe even while pings succeed")
  func unansweredOpenDemotesPipe() async throws {
    let scripted = ScriptedDirectMachine()
    let downs = Recorder()
    let connection = makeDirectConnection(to: scripted) { downs.record(Data()) }

    let recorder = Recorder()
    let answered = try await connection.openChannel(
      channelType: "ws",
      params: nil,
      onMessage: { recorder.record($0) },
      onClosed: { _ in }
    )
    #expect(await waitUntil { scripted.machine.channel(answered.id) != nil })
    let reply = try scripted.machine.sealData(channelId: answered.id, payload: Data("hi".utf8))
    scripted.sendToApp(frame: reply.frame, payload: reply.payload)
    #expect(await waitUntil { recorder.messages.count == 1 })
    // A channel that heard back says nothing about the pipe.
    await answered.reportUnanswered()
    #expect(await connection.isReady)

    let silent = try await connection.openChannel(
      channelType: "ws", params: nil, onMessage: { _ in }, onClosed: { _ in })
    await silent.reportUnanswered()
    #expect(!(await connection.isReady))
    #expect(downs.messages.count == 1)
  }

  @Test("Shutdown is silent: channels fail but onDown never fires")
  func silentShutdown() async throws {
    let scripted = ScriptedDirectMachine()
    let downs = Recorder()
    let connection = makeDirectConnection(to: scripted) { downs.record(Data()) }
    let recorder = Recorder()

    _ = try await connection.openChannel(
      channelType: "ws",
      params: nil,
      onMessage: { _ in },
      onClosed: { recorder.recordClose($0) }
    )
    await connection.shutdown()

    #expect(await waitUntil { recorder.closes.count == 1 })
    await scripted.socket.cancelled.wait()
    #expect(downs.messages.isEmpty)
  }
}

@Suite("SwitchingChannelTransport")
struct SwitchingChannelTransportTests {
  @Test("Each open asks the provider which pipe is best right now")
  func switchesPerOpen() async throws {
    let first = ScriptedDirectMachine()
    let second = ScriptedDirectMachine(
      machine: ScriptedRelayMachine(deviceId: first.machine.deviceId))
    let firstConnection = makeDirectConnection(to: first)
    let secondConnection = makeDirectConnection(to: second)
    let useSecond = Recorder()
    let transport = SwitchingChannelTransport(machineDeviceId: first.machine.deviceId) {
      useSecond.messages.isEmpty
        ? CloudDirectTransport(connection: firstConnection)
        : CloudDirectTransport(connection: secondConnection)
    }
    #expect(transport.machineDeviceId == first.machine.deviceId)

    let overFirst = try await transport.openChannel(
      channelType: "http", params: nil, compressed: false,
      onMessage: { _ in }, onClosed: { _ in })
    #expect(await waitUntil { first.machine.channel(overFirst.id) != nil })
    #expect(second.machine.channel(overFirst.id) == nil)

    useSecond.record(Data())  // the first pipe "went down"
    let overSecond = try await transport.openChannel(
      channelType: "http", params: nil, compressed: false,
      onMessage: { _ in }, onClosed: { _ in })
    #expect(await waitUntil { second.machine.channel(overSecond.id) != nil })
    #expect(first.machine.channel(overSecond.id) == nil)
  }
}
