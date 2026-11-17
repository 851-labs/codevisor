import CodevisorClient
import Foundation
import Observation

@MainActor
@Observable
public final class SandboxRestoreProgress: SandboxSetupDisplay {
  public private(set) var phases: [SessionSetupPhase] = []

  public init() {}

  public func follow(
    _ restoring: RestoringWorkspace, clonedProjectName: String?, client: any CodevisorServerClienting
  ) async {
    let tracker = begin(restoring, clonedProjectName: clonedProjectName)
    let log = Task {
      for await line in SandboxSetupLogLine.liveLog(client, machineId: restoring.sandboxId) { tracker.append(line) }
    }
    defer { log.cancel() }
    while !Task.isCancelled {
      if let sandbox = try? await client.sandboxes().first(where: { $0.id == restoring.sandboxId }) {
        Self.show(sandbox, in: tracker)
      }
      try? await Task.sleep(for: .seconds(1))
    }
  }

  func begin(_ restoring: RestoringWorkspace, clonedProjectName: String?) -> SandboxSetupTracker {
    phases = []
    let target = SandboxTarget(
      profileId: restoring.sandboxId, profileName: "", vendorId: restoring.vendorId, machineNoun: "sandbox")
    return SandboxSetupTracker(
      controller: self, steps: SandboxSetupSteps(target: target, clonedProjectName: clonedProjectName),
      showsPhases: true)
  }

  static func show(_ sandbox: ServerSandbox, in tracker: SandboxSetupTracker) {
    tracker.apply(sandbox)
    if sandbox.state == "ready" { tracker.begin(.connect) }
  }

  func showSetupStatus(_ text: String) {}

  func beginSetupPhase(_ phase: SessionSetupPhase) {
    phases.removeAll { $0.id == phase.id }
    phases.append(phase)
  }

  func mutateSetupPhase(id: String, _ transform: (inout SessionSetupPhase) -> Void) {
    guard let index = phases.firstIndex(where: { $0.id == id }) else { return }
    transform(&phases[index])
  }
}
