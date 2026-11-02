import CodevisorCore
import Foundation
import Synchronization
import Testing

@testable import CodevisorUI

@MainActor
struct ChatPluginSubscriptionsModelTests {
  private static let watcher = UUID()
  private static let quiet = UUID()

  @Test("A chat lists each subscribed event once, in subscription order, by title when the plugin gives one")
  func listsDistinctEvents() async {
    let transport = SubscriptionsTransport(bodies: [
      Self.watcher: [
        Self.subscription("s1", event: "test.ping", title: "Ping"),
        Self.subscription("s2", event: "test.counter", title: nil),
        Self.subscription("s3", event: "test.ping", title: "Ping"),
      ]
    ])
    let model = ChatPluginSubscriptionsModel()

    await model.load(sessionId: Self.watcher, client: Self.client(transport))

    #expect(model.events.map(\.label) == ["Test Events · Ping", "Test Events · test.counter"])
    #expect(transport.sessionIds == [Self.watcher.uuidString])
  }

  @Test("Switching to a chat without subscriptions, or to no chat, empties the list")
  func switchingChatsEmpties() async {
    let transport = SubscriptionsTransport(bodies: [
      Self.watcher: [Self.subscription("s1", event: "test.ping", title: "Ping")]
    ])
    let model = ChatPluginSubscriptionsModel()
    await model.load(sessionId: Self.watcher, client: Self.client(transport))
    let before = model.events.count

    await model.load(sessionId: Self.quiet, client: Self.client(transport))
    let quiet = model.events.count
    await model.load(sessionId: Self.watcher, client: Self.client(transport))
    await model.load(sessionId: nil, client: Self.client(transport))

    #expect(before == 1)
    #expect(quiet == 0)
    #expect(model.events.isEmpty)
  }

  private static func client(_ transport: SubscriptionsTransport) -> CodevisorServerClient {
    CodevisorServerClient(config: CodevisorServerConfig(requestTransport: transport))
  }

  private static func subscription(_ id: String, event: String, title: String?) -> String {
    let titleField = title.map { #","eventTitle":"\#($0)""# } ?? ""
    return """
      {"id":"\(id)","sessionId":"\(watcher.uuidString)","plugin":"dev.codevisor/test-events",\
      "pluginName":"Test Events","event":"\(event)"\(titleField),"arguments":{},"explained":"every event",\
      "once":false,"createdBy":"agent","createdAt":"2026-11-02T19:00:00.000Z"}
      """
  }
}

private final class SubscriptionsTransport: ServerRequestTransport, Sendable {
  private let bodies: [UUID: [String]]
  private let recorded = Mutex<[String]>([])
  var sessionIds: [String] { recorded.withLock { $0 } }

  init(bodies: [UUID: [String]]) {
    self.bodies = bodies
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let url = try #require(request.url)
    let sessionId =
      URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .first { $0.name == "sessionId" }?.value ?? ""
    recorded.withLock { $0.append(sessionId) }
    let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
    let subscriptions = UUID(uuidString: sessionId).flatMap { bodies[$0] } ?? []
    return (Data(#"{"subscriptions":["#.appending(subscriptions.joined(separator: ",")).appending("]}").utf8), response)
  }
}
