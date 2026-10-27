import CodevisorClient
import Foundation

public enum SandboxSetupStage: String, CaseIterable, Sendable {
  case image
  case create
  case boot
  case install
  case signIn
  case sync
  case clone
  case connect
  case agent

  static let appStages: [SandboxSetupStage] = [.connect, .agent]
}

public enum SandboxSetupUpdate: Equatable, Sendable {
  case begin(SandboxSetupStage, startedAt: Date)
  case succeed(SandboxSetupStage, durationMs: Double)
}

public struct SandboxSetupSteps: Sendable {
  public let target: SandboxTarget
  public let projectName: String
  public var agentName: String

  public init(target: SandboxTarget, projectName: String, agentName: String = "the agent") {
    self.target = target
    self.projectName = projectName
    self.agentName = agentName
  }

  public static let phaseIdPrefix = "sandbox-"

  public static func phaseId(_ stage: SandboxSetupStage) -> String {
    "\(phaseIdPrefix)\(stage.rawValue)"
  }

  public static func updates(
    steps: [ServerSandboxSetupStep],
    begun: Set<SandboxSetupStage>,
    finished: Set<SandboxSetupStage>
  ) -> [SandboxSetupUpdate] {
    steps.flatMap { step -> [SandboxSetupUpdate] in
      guard let stage = SandboxSetupStage(rawValue: step.stage), let startedAt = date(step.startedAt)
      else { return [] }
      var updates: [SandboxSetupUpdate] = []
      if !begun.contains(stage) { updates.append(.begin(stage, startedAt: startedAt)) }
      if !finished.contains(stage), let endedAt = step.endedAt.flatMap(date) {
        updates.append(.succeed(stage, durationMs: endedAt.timeIntervalSince(startedAt) * 1000))
      }
      return updates
    }
  }

  public static func upcoming(plan: [String]?, begun: Set<SandboxSetupStage>) -> [SandboxSetupStage] {
    let planned = (plan ?? []).compactMap(SandboxSetupStage.init(rawValue:)) + SandboxSetupStage.appStages
    return planned.filter { !begun.contains($0) }
  }

  public func phase(
    _ stage: SandboxSetupStage,
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

  public func status(_ stage: SandboxSetupStage) -> String {
    "\(titles(for: stage).active)…"
  }

  private typealias Titles = (active: String, completed: String, failed: String, upcoming: String)

  private func titles(for stage: SandboxSetupStage) -> Titles {
    switch stage {
    case .image: titled("Preparing", "Prepared", "prepare", "the macOS image")
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
