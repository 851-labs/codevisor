import CodevisorClient
import Foundation

public enum EphemeralSetupStage: String, CaseIterable, Sendable {
  case create
  case boot
  case install
  case signIn
  case sync
  case clone
  case connect
  case agent

  static let appStages: [EphemeralSetupStage] = [.connect, .agent]
}

public enum EphemeralSetupUpdate: Equatable, Sendable {
  case begin(EphemeralSetupStage, startedAt: Date)
  case succeed(EphemeralSetupStage, durationMs: Double)
}

public struct EphemeralSetupSteps: Sendable {
  public let target: EphemeralTarget
  public let projectName: String
  public var agentName: String

  public init(target: EphemeralTarget, projectName: String, agentName: String = "the agent") {
    self.target = target
    self.projectName = projectName
    self.agentName = agentName
  }

  public static func phaseId(_ stage: EphemeralSetupStage) -> String {
    "ephemeral-\(stage.rawValue)"
  }

  public static func updates(
    steps: [ServerEphemeralSetupStep],
    begun: Set<EphemeralSetupStage>,
    finished: Set<EphemeralSetupStage>
  ) -> [EphemeralSetupUpdate] {
    steps.flatMap { step -> [EphemeralSetupUpdate] in
      guard let stage = EphemeralSetupStage(rawValue: step.stage), let startedAt = date(step.startedAt)
      else { return [] }
      var updates: [EphemeralSetupUpdate] = []
      if !begun.contains(stage) { updates.append(.begin(stage, startedAt: startedAt)) }
      if !finished.contains(stage), let endedAt = step.endedAt.flatMap(date) {
        updates.append(.succeed(stage, durationMs: endedAt.timeIntervalSince(startedAt) * 1000))
      }
      return updates
    }
  }

  public static func upcoming(plan: [String]?, begun: Set<EphemeralSetupStage>) -> [EphemeralSetupStage] {
    let planned = (plan ?? []).compactMap(EphemeralSetupStage.init(rawValue:)) + EphemeralSetupStage.appStages
    return planned.filter { !begun.contains($0) }
  }

  public func phase(
    _ stage: EphemeralSetupStage,
    startedAt: Date = Date(),
    isPending: Bool = false
  ) -> SessionSetupPhase {
    let titles = titles(for: stage)
    return SessionSetupPhase(
      id: Self.phaseId(stage),
      activeTitle: titles.active,
      completedTitle: titles.completed,
      failedTitle: titles.failed,
      upcomingTitle: titles.upcoming,
      startedAt: startedAt,
      isPending: isPending
    )
  }

  public func status(_ stage: EphemeralSetupStage) -> String {
    "\(titles(for: stage).active)…"
  }

  private typealias Titles = (active: String, completed: String, failed: String, upcoming: String)

  private func titles(for stage: EphemeralSetupStage) -> Titles {
    switch stage {
    case .create: titled("Creating", "Created", "create", target.machineNoun)
    case .boot: titled("Booting", "Booted", "boot", target.machineNoun)
    case .install: titled("Installing", "Installed", "install", "Codevisor")
    case .signIn: titled("Signing in to", "Signed in to", "sign in to", "Codevisor")
    case .sync: titled("Syncing", "Synced", "sync", "your setup")
    case .clone: titled("Cloning", "Cloned", "clone", projectName)
    case .connect: titled("Connecting to", "Connected to", "connect to", target.machineNoun)
    case .agent: titled("Preparing", "Prepared", "prepare", agentName)
    }
  }

  private func titled(_ active: String, _ completed: String, _ verb: String, _ object: String) -> Titles {
    (
      "\(active) \(object)", "\(completed) \(object)", "Could not \(verb) \(object)",
      "\(verb.prefix(1).uppercased())\(verb.dropFirst()) \(object)"
    )
  }

  private static func date(_ text: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
  }
}
