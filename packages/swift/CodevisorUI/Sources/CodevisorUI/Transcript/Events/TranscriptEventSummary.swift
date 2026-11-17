import CodevisorCore
import SwiftUI

struct TranscriptEventSummary {
  private static let terminalSymbol = "terminal"

  let agentName: String?
  let title: String
  let icon: TranscriptEventIconKind
  var namesPartyLast = false

  var sentence: String {
    let words = namesPartyLast ? [title, agentName] : [agentName, title]
    return words.compactMap(\.self).joined(separator: " ")
  }

  @MainActor
  static func thread(_ marker: TranscriptEventMarker, agents: TranscriptEventAgents) -> TranscriptEventSummary {
    let count = marker.events.count
    return threadSummary(
      marker.events.last, title: count == 1 ? "1 message with" : "\(count) messages with", agents: agents)
  }

  static var generic: TranscriptEventSummary { .init(title: "Codevisor event", icon: .symbol("bolt")) }

  @MainActor
  init(marker: TranscriptEventMarker, agents: TranscriptEventAgents) {
    guard let first = marker.events.first else {
      self = Self.generic
      return
    }
    self.init(event: first, agents: agents)
  }

  @MainActor
  init(event: TranscriptEvent, agents: TranscriptEventAgents) {
    switch event.kind {
    case .plugin: self.init(title: Self.pluginEventTitle(event), icon: Self.pluginIcon(event))
    case .threadMessage: self = Self.threadMessage(event, agents: agents)
    case .agentMessage: self = Self.agentSummary(event, title: "sent a message", agents: agents)
    case .agentTurnEnded: self = Self.agentSummary(event, title: Self.turnEndedTitle(event), agents: agents)
    case .agentWaitingForUser: self = Self.agentSummary(event, title: Self.waitingTitle(event), agents: agents)
    case .agentErrored: self = Self.agentSummary(event, title: "hit an error", agents: agents)
    case .jobFinished: self = Self.taskSummary(event, finished: "Job finished", failed: "Job failed")
    case .backgroundTaskFinished:
      self = Self.taskSummary(event, finished: "Background task finished", failed: "Background task failed")
    case .restarted: self.init(title: "Codevisor restarted", icon: .symbol("arrow.clockwise"))
    case .usageLimitReset: self.init(title: "Usage limit reset", icon: .symbol("clock.arrow.circlepath"))
    case .questionAnswered: self.init(title: "Answer delivered", icon: .symbol("questionmark.circle"))
    case .botCreated: self.init(title: "Bot created", icon: .symbol("sparkles"))
    case .bookkeeping: self = Self.generic
    }
  }

  init(agentName: String? = nil, title: String, icon: TranscriptEventIconKind) {
    self.agentName = agentName
    self.title = title
    self.icon = icon
  }

  @MainActor
  private static func agentSummary(
    _ event: TranscriptEvent, title: String, agents: TranscriptEventAgents
  ) -> TranscriptEventSummary {
    .init(agentName: agents.name(for: event), title: title, icon: agents.icon(for: event))
  }

  @MainActor
  private static func threadMessage(_ event: TranscriptEvent, agents: TranscriptEventAgents) -> TranscriptEventSummary {
    guard event[attribute: "to"] != nil else {
      return .init(agentName: threadPartyName(event), title: "sent a message", icon: agents.threadPartyIcon(for: event))
    }
    return threadSummary(event, title: "Sent a message to", agents: agents)
  }

  @MainActor
  private static func threadSummary(
    _ event: TranscriptEvent?, title: String, agents: TranscriptEventAgents
  ) -> TranscriptEventSummary {
    var summary = TranscriptEventSummary(
      agentName: event.map(threadPartyName), title: title,
      icon: event.map(agents.threadPartyIcon) ?? .symbol(TranscriptEventAgents.threadSymbol))
    summary.namesPartyLast = true
    return summary
  }

  private static func threadPartyName(_ event: TranscriptEvent) -> String {
    guard let name = event[attribute: "name"], !name.isEmpty else { return "Agent" }
    return name
  }

  private static func turnEndedTitle(_ event: TranscriptEvent) -> String {
    event[attribute: "stopKind"] == "usageLimit" ? "paused at its usage limit" : "finished"
  }

  private static func waitingTitle(_ event: TranscriptEvent) -> String {
    event[attribute: "kind"] == "planApproval" ? "proposed a plan" : "asked a question"
  }

  private static func taskSummary(_ event: TranscriptEvent, finished: String, failed: String) -> TranscriptEventSummary
  {
    .init(title: didFail(event) ? failed : finished, icon: .symbol(terminalSymbol))
  }

  private static func didFail(_ event: TranscriptEvent) -> Bool {
    event[attribute: "status"] == "failed" || event[attribute: "state"] == "failed"
  }

  private static func pluginEventTitle(_ event: TranscriptEvent) -> String {
    event[attribute: "label"] ?? event[attribute: "eventTitle"] ?? "Plugin event"
  }

  private static func pluginIcon(_ event: TranscriptEvent) -> TranscriptEventIconKind {
    if let symbol = event[attribute: "symbol"] { return .symbol(symbol) }
    return event[attribute: "pluginId"].map(TranscriptEventIconKind.plugin) ?? .symbol("puzzlepiece.extension")
  }
}
