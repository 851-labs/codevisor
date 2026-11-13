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

  @Test("A Clock wake-up is named by the automation's own label, next to its symbol")
  func clockEventLabel() {
    let event = TranscriptEvent(
      type: "plugin.event",
      attributes: [
        "plugin": "Clock", "pluginId": "codevisor.clock", "event": "every", "eventTitle": "On a schedule",
        "label": "Tuesdays at 3:00 PM", "symbol": "clock",
      ],
      body: "")
    let summary = TranscriptEventSummary(event: event, agents: agents)

    #expect(summary.title == "Tuesdays at 3:00 PM")
    guard case let .symbol(name) = summary.icon else {
      Issue.record("Expected a symbol icon")
      return
    }
    #expect(name == "clock")
  }

  @Test("Thread messages read as a count with the other side, and one alone says which way it went")
  func threadMessages() throws {
    let received = TranscriptEvent(
      type: "thread.message", attributes: ["threadId": "t1", "from": "bot", "botId": "b1", "name": "Triage"], body: "")
    let sent = TranscriptEvent(
      type: "thread.message", attributes: ["threadId": "t1", "to": "agent", "agentId": "a1", "name": ""], body: "")
    let one = try #require(marker("to", "Is it green?"))
    let two = try #require(marker("to", "Is it green?", "from", "Yes."))

    #expect(TranscriptEventSummary.thread(one, agents: agents).sentence == "1 message with Triage")
    #expect(TranscriptEventSummary.thread(two, agents: agents).sentence == "2 messages with Triage")
    #expect(TranscriptEventSummary(event: received, agents: agents).sentence == "Triage sent a message")
    #expect(TranscriptEventSummary(event: sent, agents: agents).sentence == "Sent a message to Agent")
  }

  private func marker(_ parts: String...) -> TranscriptEventMarker? {
    let events = stride(from: 0, to: parts.count, by: 2).map { index in
      """
      <codevisor-event type="thread.message" threadId="t1" \(parts[index])="bot" botId="b1" name="Triage">
      \(parts[index + 1])
      </codevisor-event>
      """
    }
    return TranscriptEventMarker(message: UserMessage(text: events.joined(separator: "\n"), isEvent: true))
  }
}
