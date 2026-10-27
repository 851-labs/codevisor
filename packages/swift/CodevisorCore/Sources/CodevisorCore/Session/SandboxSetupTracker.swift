import CodevisorClient
import Foundation

@MainActor
final class SandboxSetupTracker {
  let steps: SandboxSetupSteps
  private weak var controller: SessionController?
  private let showsPhases: Bool
  private var begun: Set<SandboxSetupStage> = []
  private var finished: Set<SandboxSetupStage> = []
  private var upcoming: Set<SandboxSetupStage> = []
  private var current: SandboxSetupStage?

  init(controller: SessionController, steps: SandboxSetupSteps, showsPhases: Bool) {
    self.controller = controller
    self.steps = steps
    self.showsPhases = showsPhases
  }

  func apply(_ machine: ServerSandbox) {
    showUpcoming(SandboxSetupSteps.upcoming(plan: machine.plan, begun: begun))
    let updates = SandboxSetupSteps.updates(steps: machine.steps ?? [], begun: begun, finished: finished)
    for update in updates {
      switch update {
      case let .begin(stage, startedAt): begin(stage, startedAt: startedAt)
      case let .succeed(stage, durationMs): succeed(stage, durationMs: durationMs)
      }
    }
  }

  func append(_ line: SandboxSetupLogLine) {
    guard let stage = SandboxSetupStage(rawValue: line.stage) ?? current else { return }
    if !begun.contains(stage) { begin(stage) }
    mutate(stage) { $0.appendLog(stream: line.stream, line: line.line) }
  }

  func note(_ line: String, in stage: SandboxSetupStage) {
    mutate(stage) { $0.appendLog(stream: "stdout", line: line) }
  }

  func begin(_ stage: SandboxSetupStage, startedAt: Date = Date()) {
    guard !begun.contains(stage) else { return }
    begun.insert(stage)
    current = stage
    controller?.status = .connecting(steps.status(stage))
    if upcoming.remove(stage) != nil {
      mutate(stage) { $0.start(at: startedAt) }
    } else if showsPhases {
      controller?.beginSetupPhase(steps.phase(stage, startedAt: startedAt))
    }
  }

  private func showUpcoming(_ stages: [SandboxSetupStage]) {
    guard showsPhases, upcoming.isEmpty, begun.count <= 1 else { return }
    for stage in stages where !upcoming.contains(stage) {
      upcoming.insert(stage)
      controller?.beginSetupPhase(steps.phase(stage, isPending: true))
    }
  }

  func succeed(_ stage: SandboxSetupStage, durationMs: Double? = nil) {
    guard begun.contains(stage), !finished.contains(stage) else { return }
    finished.insert(stage)
    mutate(stage) { $0.succeed(durationMs: durationMs) }
  }

  func failCurrent(_ message: String) {
    guard let current, !finished.contains(current) else { return }
    finished.insert(current)
    mutate(current) { $0.fail(message: message) }
  }

  private func mutate(_ stage: SandboxSetupStage, _ transform: (inout SessionSetupPhase) -> Void) {
    guard showsPhases else { return }
    controller?.mutateSetupPhase(id: SandboxSetupSteps.phaseId(stage), transform)
  }
}
