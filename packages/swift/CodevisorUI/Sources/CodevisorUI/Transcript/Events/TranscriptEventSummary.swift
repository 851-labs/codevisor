import CodevisorCore
import SwiftUI

struct TranscriptEventSummary {
  enum Tone {
    case standard
    case error

    func style(standard standardStyle: HierarchicalShapeStyle) -> AnyShapeStyle {
      switch self {
      case .standard: AnyShapeStyle(standardStyle)
      case .error: AnyShapeStyle(Color.red)
      }
    }
  }

  private static let terminalSymbol = "terminal"

  let agentName: String?
  let title: String
  let icon: TranscriptEventIconKind
  var tone = Tone.standard
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

  @MainActor
  init(marker: TranscriptEventMarker, agents: TranscriptEventAgents) {
    guard let first = marker.events.first else {
      self.init(title: "Codevisor event", icon: .symbol("bolt"))
      return
    }
    self.init(event: first, agents: agents)
  }

  @MainActor
  init(event: TranscriptEvent, agents: TranscriptEventAgents) {
    if event.threadID != nil {
      self = Self.threadMessage(event, agents: agents)
      return
    }
    guard TranscriptEventAgents.isAgentEvent(event) else {
      self = Self.systemSummary(event)
      return
    }
    self = Self.agentSummary(event, name: agents.name(for: event), icon: agents.icon(for: event))
  }

  init(agentName: String? = nil, title: String, icon: TranscriptEventIconKind, tone: Tone = .standard) {
    self.agentName = agentName
    self.title = title
    self.icon = icon
    self.tone = tone
  }

  private static func agentSummary(
    _ event: TranscriptEvent, name: String, icon: TranscriptEventIconKind
  ) -> TranscriptEventSummary {
    switch event.type {
    case "session.turn_ended": .init(agentName: name, title: turnEndedTitle(event), icon: icon)
    case "session.waiting_for_user": .init(agentName: name, title: waitingTitle(event), icon: icon)
    case "session.errored": .init(agentName: name, title: "hit an error", icon: icon, tone: .error)
    default: .init(agentName: name, title: "sent a message", icon: icon)
    }
  }

  private static func systemSummary(_ event: TranscriptEvent) -> TranscriptEventSummary {
    switch event.type {
    case "execution.job_finished": taskSummary(event, finished: "Job finished", failed: "Job failed")
    case "exec.task_finished", "harness.task_finished":
      taskSummary(event, finished: "Background task finished", failed: "Background task failed")
    case "plugin.event": .init(title: pluginEventTitle(event), icon: pluginIcon(event))
    case "session.restarted": .init(title: "Codevisor restarted", icon: .symbol("arrow.clockwise"))
    case "session.usage_limit_reset": .init(title: "Usage limit reset", icon: .symbol("clock.arrow.circlepath"))
    case "question.answered": .init(title: "Answer delivered", icon: .symbol("questionmark.circle"))
    default: .init(title: "Codevisor event", icon: .symbol("bolt"))
    }
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
    guard didFail(event) else { return .init(title: finished, icon: .symbol(terminalSymbol)) }
    return .init(title: failed, icon: .symbol(terminalSymbol), tone: .error)
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
