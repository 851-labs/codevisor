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

  let title: String
  let icon: TranscriptEventIconKind
  var tone = Tone.standard

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
    guard TranscriptEventAgents.isAgentEvent(event) else {
      self = Self.systemSummary(event)
      return
    }
    let noun = agents.bot(for: event) == nil ? "Agent" : "Bot"
    self = Self.agentSummary(event, noun: noun, icon: agents.icon(for: event))
  }

  init(title: String, icon: TranscriptEventIconKind, tone: Tone = .standard) {
    self.title = title
    self.icon = icon
    self.tone = tone
  }

  private static func agentSummary(
    _ event: TranscriptEvent, noun: String, icon: TranscriptEventIconKind
  ) -> TranscriptEventSummary {
    switch event.type {
    case "session.turn_ended": .init(title: turnEndedTitle(event, noun: noun), icon: icon)
    case "session.waiting_for_user": .init(title: waitingTitle(event, noun: noun), icon: icon)
    case "session.errored": .init(title: "\(noun) hit an error", icon: icon, tone: .error)
    default: .init(title: "Message from \(noun.lowercased())", icon: icon)
    }
  }

  private static func systemSummary(_ event: TranscriptEvent) -> TranscriptEventSummary {
    switch event.type {
    case "execution.job_finished": taskSummary(event, finished: "Job finished", failed: "Job failed")
    case "exec.task_finished", "harness.task_finished":
      taskSummary(event, finished: "Background task finished", failed: "Background task failed")
    case "plugin.event": .init(title: "Plugin event", icon: pluginIcon(event))
    case "session.restarted": .init(title: "Codevisor restarted", icon: .symbol("arrow.clockwise"))
    case "session.usage_limit_reset": .init(title: "Usage limit reset", icon: .symbol("clock.arrow.circlepath"))
    case "question.answered": .init(title: "Answer delivered", icon: .symbol("questionmark.circle"))
    default: .init(title: "Codevisor event", icon: .symbol("bolt"))
    }
  }

  private static func turnEndedTitle(_ event: TranscriptEvent, noun: String) -> String {
    event[attribute: "stopKind"] == "usageLimit" ? "\(noun) paused at its usage limit" : "\(noun) finished"
  }

  private static func waitingTitle(_ event: TranscriptEvent, noun: String) -> String {
    event[attribute: "kind"] == "planApproval" ? "\(noun) wants a plan approved" : "\(noun) needs input"
  }

  private static func taskSummary(_ event: TranscriptEvent, finished: String, failed: String) -> TranscriptEventSummary
  {
    guard didFail(event) else { return .init(title: finished, icon: .symbol(terminalSymbol)) }
    return .init(title: failed, icon: .symbol(terminalSymbol), tone: .error)
  }

  private static func didFail(_ event: TranscriptEvent) -> Bool {
    event[attribute: "status"] == "failed" || event[attribute: "state"] == "failed"
  }

  private static func pluginIcon(_ event: TranscriptEvent) -> TranscriptEventIconKind {
    event[attribute: "pluginId"].map(TranscriptEventIconKind.plugin) ?? .symbol("puzzlepiece.extension")
  }
}
