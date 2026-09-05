import CodevisorTestSupport
import Foundation
import Testing
import ACPKit
import CodevisorClient
import CodevisorProtocol
@testable import CodevisorCloud

@Suite("CloudRelayTransport")
struct CloudRelayTransportTests {
  @Test("Chunked ws frames reassemble into one message; unknown kinds are skipped")
  func wsChunkReassembly() async throws {
    let scriptedMachine = ScriptedWsMachine()
    let (endpoint, hub) = makeRelayEndpoint(
      scripted: scriptedMachine.scripted, machine: scriptedMachine.machine)
    let socket = CloudRelayWebSocketTransport(endpoint: endpoint).connect(
      URLRequest(url: URL(string: "https://relay.invalid/v1/sessions/x/events/socket")!),
      maximumMessageSize: 1 << 20
    )
    let base64 = { (piece: String) in CloudChannelCrypto.base64URLEncode(Data(piece.utf8)) }

    let first = Task { try await socket.receive() }
    #expect(await waitUntil { scriptedMachine.openChannelId != nil })
    scriptedMachine.push(#"{"kind":"part","data":"\#(base64("hello, "))"}"#)
    // Unknown future kinds are skipped, never spliced into a message.
    scriptedMachine.push(#"{"kind":"future-frame","data":"ignored"}"#)
    scriptedMachine.push(#"{"kind":"text-end","data":"\#(base64("chunked world"))"}"#)
    #expect(relayMessageText(try await first.value) == "hello, chunked world")

    // Plain frames pass through untouched after a chunked message.
    let second = Task { try await socket.receive() }
    scriptedMachine.push(#"{"kind":"text","data":"plain"}"#)
    #expect(relayMessageText(try await second.value) == "plain")

    // Binary messages reassemble the same way.
    let third = Task { try await socket.receive() }
    scriptedMachine.push(#"{"kind":"part","data":"\#(base64("01"))"}"#)
    scriptedMachine.push(#"{"kind":"binary-end","data":"\#(base64("23"))"}"#)
    #expect(relayMessageBinary(try await third.value) == Data("0123".utf8))

    socket.cancel(with: .goingAway, reason: nil)
    await hub.shutdown()
  }

  @Test("HTTP requests round-trip: method, path+query, headers, chunked bodies")
  func httpRoundTrip() async throws {
    let scriptedMachine = ScriptedHttpMachine()
    let responseBody = Data("{\"ok\":true,\"version\":\"1.2.3\"}".utf8)
    scriptedMachine.respond = { request in
      ScriptedHttpMachine.ScriptedResponse(
        status: 200,
        headers: ["Content-Type": "application/json"],
        // Two chunks prove reassembly order.
        bodyChunks: [responseBody.prefix(10), responseBody.dropFirst(10)]
      )
    }
    let (endpoint, hub) = makeRelayEndpoint(
      scripted: scriptedMachine.scripted, machine: scriptedMachine.machine)
    let transport = CloudRelayRequestTransport(endpoint: endpoint)

    // A body bigger than one chunk exercises request-side chunking.
    let requestBody = Data((0..<(CloudRelayRequestTransport.chunkSize + 1000)).map { UInt8($0 % 251) })
    var request = URLRequest(
      url: URL(string: "https://cloud-relay.invalid/v1/health?probe=1")!
    )
    request.httpMethod = "POST"
    request.httpBody = requestBody
    request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")

    let (data, response) = try await transport.data(for: request)

    #expect(response.statusCode == 200)
    #expect(response.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(data == responseBody)
    let received = try #require(scriptedMachine.completedRequests.first)
    #expect(received.method == "POST")
    #expect(received.path == "/v1/health?probe=1")
    #expect(received.headers["Authorization"] == "Bearer secret")
    #expect(received.body == requestBody)
    await hub.shutdown()
  }

  @Test("A rejected close surfaces as an error")
  func rejectedRequest() async throws {
    let scriptedMachine = ScriptedHttpMachine()
    scriptedMachine.respond = { _ in
      ScriptedHttpMachine.ScriptedResponse(
        status: 0, headers: [:], bodyChunks: [], closeReason: .rejected
      )
    }
    let (endpoint, hub) = makeRelayEndpoint(
      scripted: scriptedMachine.scripted, machine: scriptedMachine.machine)
    let transport = CloudRelayRequestTransport(endpoint: endpoint)

    await #expect(throws: CloudRelayTransportError.channelClosed(.rejected)) {
      _ = try await transport.data(
        for: URLRequest(url: URL(string: "https://cloud-relay.invalid/v1/info")!)
      )
    }
    await hub.shutdown()
  }

  @Test("A request whose channel never answers times out instead of hanging")
  func requestTimesOut() async throws {
    let scriptedMachine = ScriptedHttpMachine()
    // respond stays nil: the machine accepts the open but never replies.
    let (endpoint, hub) = makeRelayEndpoint(
      scripted: scriptedMachine.scripted, machine: scriptedMachine.machine)
    let clock = TestClock()
    let transport = CloudRelayRequestTransport(endpoint: endpoint, sleep: clock.sleep)

    let request = Task {
      try await transport.data(for: URLRequest(url: URL(string: "https://cloud-relay.invalid/v1/info")!))
    }
    #expect(await waitUntil { !scriptedMachine.openChannelIds.isEmpty })
    await clock.waitForSleep(.seconds(30))
    clock.advance(by: .seconds(30))
    await #expect(throws: CloudRelayTransportError.timedOut) { try await request.value }
    await hub.shutdown()
  }

  @Test("A real server client works end-to-end over the relay transport")
  func serverClientOverRelay() async throws {
    let scriptedMachine = ScriptedHttpMachine()
    scriptedMachine.respond = { request in
      guard request.path == "/v1/info" else {
        return ScriptedHttpMachine.ScriptedResponse(
          status: 404, headers: [:], bodyChunks: [Data("{}".utf8)]
        )
      }
      let info = Data(
        """
        {"id":"m1","name":"Relay Mac","kind":"remote","version":"9.9.9",
         "platform":"darwin","bindHost":"127.0.0.1","cloudDeviceId":"machine-1"}
        """.utf8)
      return ScriptedHttpMachine.ScriptedResponse(
        status: 200,
        headers: ["Content-Type": "application/json"],
        bodyChunks: [info]
      )
    }
    let (endpoint, hub) = makeRelayEndpoint(
      scripted: scriptedMachine.scripted, machine: scriptedMachine.machine)
    let client = CodevisorServerClient(
      config: CodevisorServerConfig(
        baseURL: CodevisorMachine.cloudPlaceholderBaseURL,
        requestTransport: CloudRelayRequestTransport(endpoint: endpoint),
        webSocketTransport: CloudRelayWebSocketTransport(endpoint: endpoint)
      ))

    let info = try await client.info()
    #expect(info.name == "Relay Mac")
    #expect(info.cloudDeviceId == "machine-1")
    await hub.shutdown()
  }
}
