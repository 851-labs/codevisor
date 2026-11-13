import CodevisorCore
import Testing

@testable import CodevisorUI

@MainActor
struct TranscriptEventSummaryTests {
  private let agents = TranscriptEventAgents(sessions: [], bots: nil)

  private func title(_ attributes: [String: String]) -> String {
    let event = TranscriptEvent(type: "plugin.event", attributes: attributes, body: "")
    return TranscriptEventSummary(event: event, agents: agents).title
  }

  @Test("A plugin event is named by the event's title, next to the plugin's icon")
  func pluginEventTitle() {
    #expect(title(["plugin": "Slack", "event": "message.posted", "eventTitle": "New message"]) == "New message")
    #expect(title(["plugin": "Slack", "event": "message.posted"]) == "Plugin event")
  }
}
