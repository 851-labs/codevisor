import CodevisorClient
import Foundation

@MainActor
final class EphemeralSetupTracker {
  let steps: EphemeralSetupSteps
  private weak var controller: SessionController?
  private let showsPhases: Bool
  private var begun: Set<EphemeralSetupStage> = []
  private var finished: Set<EphemeralSetupStage> = []
  private var upcoming: Set<EphemeralSetupStage> = []
  private var current: EphemeralSetupStage?

  init(controller: SessionController, steps: EphemeralSetupSteps, showsPhases: Bool) {
    self.controller = controller
    self.steps = steps
    self.showsPhases = showsPhases
  }

  func apply(_ machine: ServerEphemeralMachine) {
    showUpcoming(EphemeralSetupSteps.upcoming(plan: machine.plan, begun: begun))
    let updates = EphemeralSetupSteps.updates(steps: machine.steps ?? [], begun: begun, finished: finished)
    for update in updates {
      switch update {
      case let .begin(stage, startedAt): begin(stage, startedAt: startedAt)
      case let .succeed(stage, durationMs): succeed(stage, durationMs: durationMs)
      }
    }
  }

  func append(_ line: EphemeralSetupLogLine) {
    guard let stage = EphemeralSetupStage(rawValue: line.stage) ?? current else { return }
    if !begun.contains(stage) { begin(stage) }
    mutate(stage) { $0.appendLog(stream: line.stream, line: line.line) }
  }

  func note(_ line: String, in stage: EphemeralSetupStage) {
    mutate(stage) { $0.appendLog(stream: "stdout", line: line) }
  }

  func begin(_ stage: EphemeralSetupStage, startedAt: Date = Date()) {
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

  private func showUpcoming(_ stages: [EphemeralSetupStage]) {
    guard showsPhases, upcoming.isEmpty, begun.count <= 1 else { return }
    for stage in stages where !upcoming.contains(stage) {
      upcoming.insert(stage)
      controller?.beginSetupPhase(steps.phase(stage, isPending: true))
    }
  }

  func succeed(_ stage: EphemeralSetupStage, durationMs: Double? = nil) {
    guard begun.contains(stage), !finished.contains(stage) else { return }
    finished.insert(stage)
    mutate(stage) { $0.succeed(durationMs: durationMs) }
  }

  func failCurrent(_ message: String) {
    guard let current, !finished.contains(current) else { return }
    finished.insert(current)
    mutate(current) { $0.fail(message: message) }
  }

  private func mutate(_ stage: EphemeralSetupStage, _ transform: (inout SessionSetupPhase) -> Void) {
    guard showsPhases else { return }
    controller?.mutateSetupPhase(id: EphemeralSetupSteps.phaseId(stage), transform)
  }
}
