import CodevisorCore
import Foundation
import Synchronization
import Testing

@testable import CodevisorUI

@MainActor
struct ChatPluginSubscriptionsModelTests {
  private static let watcher = UUID()
  private static let quiet = UUID()

  @Test("A chat lists each automation as its own row, in subscription order, by title when the plugin gives one")
  func listsEachAutomation() async {
    let transport = SubscriptionsTransport(bodies: [
      Self.watcher: [
        Self.subscription("s1", event: "test.ping", title: "Ping"),
        Self.subscription("s2", event: "test.counter", title: nil),
        Self.subscription("s3", event: "test.ping", title: "Ping"),
      ]
    ])
    let model = ChatPluginSubscriptionsModel()

    await model.load(sessionId: Self.watcher, client: Self.client(transport))

    #expect(model.events.map(\.id) == ["s1", "s2", "s3"])
    #expect(model.events.map(\.label) == ["Test Events · Ping", "Test Events · test.counter", "Test Events · Ping"])
    #expect(transport.sessionIds == [Self.watcher.uuidString])
  }

  @Test("Clock subscriptions each get their own row, named by their own label, with a due time to count down to")
  func listsClockSubscriptionsByLabel() async {
    let transport = SubscriptionsTransport(bodies: [
      Self.watcher: [
        Self.clock("c1", event: "every", label: "Tuesdays at 3:00 PM", firesAt: nil),
        Self.clock("c2", event: "after", label: "Nov 13, 9:40 AM", firesAt: "2026-11-13T17:40:00.000Z"),
        Self.clock("c3", event: "after", label: "Nov 13, 9:50 AM", firesAt: "2026-11-13T17:50:00.000Z"),
      ]
    ])
    let model = ChatPluginSubscriptionsModel()

    await model.load(sessionId: Self.watcher, client: Self.client(transport))

    #expect(
      model.events.map(\.label) == [
        "Clock · Tuesdays at 3:00 PM", "Clock · Nov 13, 9:40 AM", "Clock · Nov 13, 9:50 AM",
      ])
    #expect(
      model.events.map(\.firesAt) == [
        nil, Date(timeIntervalSince1970: 1_794_591_600), Date(timeIntervalSince1970: 1_794_592_200),
      ])
  }

  @Test("Removing an automation unsubscribes it on the server and drops its row")
  func removesAutomation() async throws {
    let transport = SubscriptionsTransport(bodies: [
      Self.watcher: [
        Self.subscription("s1", event: "test.ping", title: "Ping"),
        Self.subscription("s2", event: "test.counter", title: nil),
      ]
    ])
    let model = ChatPluginSubscriptionsModel()
    await model.load(sessionId: Self.watcher, client: Self.client(transport))
    let ping = try #require(model.events.first)

    let removed = await model.remove(ping, client: Self.client(transport))

    #expect(removed)
    #expect(transport.deleted == ["/v1/plugins/events/subscriptions/s1"])
    #expect(model.events.map(\.id) == ["s2"])
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

  private static func clock(_ id: String, event: String, label: String, firesAt: String?) -> String {
    let firesAtField = firesAt.map { #","firesAt":"\#($0)""# } ?? ""
    return """
      {"id":"\(id)","sessionId":"\(watcher.uuidString)","plugin":"codevisor.clock","pluginName":"Clock",\
      "symbolName":"clock","event":"\(event)","label":"\(label)"\(firesAtField),"arguments":{},\
      "explained":"x","once":false,"createdBy":"agent","createdAt":"2026-11-13T17:10:00.000Z"}
      """
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
  private let deletions = Mutex<[String]>([])
  var sessionIds: [String] { recorded.withLock { $0 } }
  var deleted: [String] { deletions.withLock { $0 } }

  init(bodies: [UUID: [String]]) {
    self.bodies = bodies
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let url = try #require(request.url)
    let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
    if request.httpMethod == "DELETE" {
      deletions.withLock { $0.append(url.path) }
      return (Data(#"{"removed":true}"#.utf8), response)
    }
    let sessionId =
      URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
      .first { $0.name == "sessionId" }?.value ?? ""
    recorded.withLock { $0.append(sessionId) }
    let subscriptions = UUID(uuidString: sessionId).flatMap { bodies[$0] } ?? []
    return (Data(#"{"subscriptions":["#.appending(subscriptions.joined(separator: ",")).appending("]}").utf8), response)
  }
}
