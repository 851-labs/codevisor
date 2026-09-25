import CodevisorTestSupport
import Foundation
import Testing
import ACPKit
import CodevisorClient
@testable import CodevisorCloud

/// Phase 6 behavior: http/ws channels run under negotiated credit-based flow
/// control in both directions, and streamed responses are consumer-paced.
@Suite("CloudRelay flow control")
struct CloudRelayFlowControlTests {
  @Test("Uploads gate on the machine's window: no grant, no frames")
  func uploadGatesOnCredit() async throws {
    let scriptedMachine = ScriptedHttpMachine()
    scriptedMachine.grantsUploadWindow = false
    scriptedMachine.respond = { _ in
      ScriptedHttpMachine.ScriptedResponse(status: 200, headers: [:], bodyChunks: [])
    }
    let (endpoint, hub) = makeRelayEndpoint(
      scripted: scriptedMachine.scripted, machine: scriptedMachine.machine)
    let clock = TestClock()
    let transport = CloudRelayRequestTransport(endpoint: endpoint, sleep: clock.sleep)
    var request = URLRequest(url: URL(string: "https://cloud-relay.invalid/v1/upload")!)
    request.httpMethod = "POST"
    request.httpBody = Data("held until granted".utf8)

    let pending = Task { try await transport.data(for: request) }
    #expect(await waitUntil { !scriptedMachine.openChannelIds.isEmpty })
    await clock.waitForSleep(.seconds(30))
    clock.advance(by: .seconds(30))
    await #expect(throws: CloudRelayTransportError.timedOut) { try await pending.value }
    // Not even the first chunk frame made it out.
    #expect(scriptedMachine.completedRequests.isEmpty)
    await hub.shutdown()
  }

  @Test("A late grant releases a waiting upload")
  func lateGrantReleasesUpload() async throws {
    let scriptedMachine = ScriptedHttpMachine()
    scriptedMachine.grantsUploadWindow = false
    scriptedMachine.respond = { request in
      ScriptedHttpMachine.ScriptedResponse(
        status: 200, headers: [:], bodyChunks: [request.body])
    }
    let (endpoint, hub) = makeRelayEndpoint(
      scripted: scriptedMachine.scripted, machine: scriptedMachine.machine)
    let transport = CloudRelayRequestTransport(endpoint: endpoint)
    var request = URLRequest(url: URL(string: "https://cloud-relay.invalid/v1/upload")!)
    request.httpMethod = "POST"
    request.httpBody = Data("held until granted".utf8)

    let pending = Task { try await transport.data(for: request) }
    #expect(await waitUntil { !scriptedMachine.openChannelIds.isEmpty })
    let channelId = scriptedMachine.openChannelIds[0]
    scriptedMachine.grantUploadWindow(channelId: channelId)

    let (data, response) = try await pending.value
    #expect(response.statusCode == 200)
    #expect(data == Data("held until granted".utf8))
    await hub.shutdown()
  }

  /// A file spanning three body chunks, the last one short.
  private func uploadFixture() throws -> (url: URL, contents: Data) {
    let count = CloudRelayRequestTransport.chunkSize * 3 - 100
    let contents = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("relay-upload-\(UUID().uuidString).bin")
    try contents.write(to: url)
    return (url, contents)
  }

  private func uploadRequest() -> URLRequest {
    var request = URLRequest(url: URL(string: "https://cloud-relay.invalid/v1/files?name=clip.mov")!)
    request.httpMethod = "POST"
    return request
  }

  /// Covers one chunk frame's sealed cost but not two, so each grant
  /// releases exactly one chunk.
  private static let oneChunkGrant = 400_000

  @Test("A file upload streams chunk by chunk, paced by grants, for longer than the timeout")
  func fileUploadIdleDeadline() async throws {
    let (fileURL, contents) = try uploadFixture()
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let scriptedMachine = ScriptedHttpMachine()
    scriptedMachine.grantsUploadWindow = false
    scriptedMachine.respond = { request in
      ScriptedHttpMachine.ScriptedResponse(
        status: 201, headers: [:], bodyChunks: [Data("\(request.body.count)".utf8)])
    }
    let (endpoint, hub) = makeRelayEndpoint(
      scripted: scriptedMachine.scripted, machine: scriptedMachine.machine)
    let clock = TestClock()
    let transport = CloudRelayRequestTransport(endpoint: endpoint, sleep: clock.sleep)

    let pending = Task { try await transport.upload(for: uploadRequest(), fromFile: fileURL) }
    #expect(await waitUntil { !scriptedMachine.openChannelIds.isEmpty })
    let channelId = scriptedMachine.openChannelIds[0]
    // 20s between grants, 60s in all: past a fixed 30s deadline, but the
    // upload never idles for 30s.
    for chunk in 1...3 {
      await clock.waitForSleep(.seconds(30))
      clock.advance(by: .seconds(20))
      scriptedMachine.grantUploadWindow(channelId: channelId, bytes: Self.oneChunkGrant)
      let expected = min(chunk * CloudRelayRequestTransport.chunkSize, contents.count)
      #expect(await waitUntil { scriptedMachine.receivedBodyBytes(channelId: channelId) >= expected })
      // No more credit, so the next chunk cannot have gone out.
      #expect(scriptedMachine.receivedBodyBytes(channelId: channelId) == expected)
    }

    let (data, response) = try await pending.value
    #expect(response.statusCode == 201)
    #expect(data == Data("\(contents.count)".utf8))
    #expect(scriptedMachine.completedRequests.first?.body == contents)
    await hub.shutdown()
  }

  @Test("A file upload that stalls fails with the transport timeout")
  func stalledFileUploadTimesOut() async throws {
    let (fileURL, _) = try uploadFixture()
    defer { try? FileManager.default.removeItem(at: fileURL) }
    let scriptedMachine = ScriptedHttpMachine()
    scriptedMachine.grantsUploadWindow = false
    scriptedMachine.respond = { _ in
      ScriptedHttpMachine.ScriptedResponse(status: 201, headers: [:], bodyChunks: [])
    }
    let (endpoint, hub) = makeRelayEndpoint(
      scripted: scriptedMachine.scripted, machine: scriptedMachine.machine)
    let clock = TestClock()
    let transport = CloudRelayRequestTransport(endpoint: endpoint, sleep: clock.sleep)

    let pending = Task { try await transport.upload(for: uploadRequest(), fromFile: fileURL) }
    #expect(await waitUntil { !scriptedMachine.openChannelIds.isEmpty })
    await clock.waitForSleep(.seconds(30))
    clock.advance(by: .seconds(30))

    await #expect(throws: CloudRelayTransportError.timedOut) { try await pending.value }
    #expect(scriptedMachine.completedRequests.isEmpty)
    await hub.shutdown()
  }

  @Test("Streamed responses replenish the machine's window per consumed chunk")
  func streamingReplenishesWindow() async throws {
    let first = Data(repeating: 0x61, count: 2_048)
    let second = Data(repeating: 0x62, count: 2_048)
    let scriptedMachine = ScriptedHttpMachine()
    scriptedMachine.respond = { _ in
      ScriptedHttpMachine.ScriptedResponse(
        status: 200, headers: [:], bodyChunks: [first, second], sendsClose: false)
    }
    let (endpoint, hub) = makeRelayEndpoint(
      scripted: scriptedMachine.scripted, machine: scriptedMachine.machine)
    let transport = CloudRelayRequestTransport(endpoint: endpoint)
    let request = URLRequest(url: URL(string: "https://cloud-relay.invalid/v1/big")!)

    let (response, body) = try await transport.stream(for: request)
    #expect(response.statusCode == 200)
    var chunks: [Data] = []
    for try await chunk in body {
      chunks.append(chunk)
    }
    #expect(chunks == [first, second])

    // The app granted its initial window plus one replenish per consumed
    // frame (head, two chunks, end).
    #expect(await waitUntil { scriptedMachine.creditGrants.count >= 5 })
    #expect(scriptedMachine.creditGrants[0] == 1024 * 1024)

    // The open advertised both negotiations to the machine.
    struct OpenProbe: Decodable {
      var compress: Bool?
      var flowControl: Bool?
    }
    let openPayload = try #require(
      scriptedMachine.machine.channel(scriptedMachine.openChannelIds[0])?.openPayload)
    let probe = try JSONDecoder().decode(OpenProbe.self, from: openPayload)
    #expect(probe.compress == true)
    #expect(probe.flowControl == true)
    await hub.shutdown()
  }

  @Test("ws windows replenish only as messages are consumed")
  func wsConsumerPacedCredit() async throws {
    let scriptedMachine = ScriptedWsMachine()
    let (endpoint, hub) = makeRelayEndpoint(
      scripted: scriptedMachine.scripted, machine: scriptedMachine.machine)
    let connection = CloudRelayWebSocketTransport(endpoint: endpoint).connect(
      URLRequest(url: URL(string: "https://cloud-relay.invalid/v1/events/socket")!),
      maximumMessageSize: 1024 * 1024
    )
    try await connection.send(.string("subscribe"))
    #expect(await waitUntil { scriptedMachine.openChannelId != nil })

    let credits: @Sendable () -> Int = {
      scriptedMachine.scripted.relayEnvelopes.filter {
        if case .credit = $0.frame { return true }
        return false
      }.count
    }
    // Settled: the app's initial window grant only.
    #expect(await waitUntil { credits() == 1 })

    scriptedMachine.push(#"{"kind":"text","data":"one"}"#)
    scriptedMachine.push(#"{"kind":"text","data":"two"}"#)
    #expect(relayMessageText(try await connection.receive()) == "one")
    #expect(await waitUntil { credits() == 2 })
    // The second message is delivered but unconsumed — no grant for it.
    await scriptedMachine.scripted.socket.drain()
    #expect(credits() == 2)
    #expect(relayMessageText(try await connection.receive()) == "two")
    #expect(await waitUntil { credits() == 3 })

    connection.cancel(with: .normalClosure, reason: nil)
    await hub.shutdown()
  }
}
