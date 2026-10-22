import Foundation

struct HarnessUpdateStatus: Equatable, Sendable {
  let isActive: Bool
  let message: String?
  let canCancel: Bool

  static let idle = HarnessUpdateStatus(isActive: false, message: nil, canCancel: false)

  static func of(
    _ harness: ServerHarness,
    run: ServerUpdateRunState?,
    pauseIsHarnessScoped: Bool
  ) -> HarnessUpdateStatus {
    guard let run, run.includes(harnessId: harness.id) else { return lifecycleStatus(harness) }

    return runStatus(harness, run: run, pauseIsHarnessScoped: pauseIsHarnessScoped)
      ?? lifecycleStatus(harness)
  }

  private static func runStatus(
    _ harness: ServerHarness,
    run: ServerUpdateRunState,
    pauseIsHarnessScoped: Bool
  ) -> HarnessUpdateStatus? {
    switch run.state {
    case "pausing":
      HarnessUpdateStatus(isActive: true, message: pausingMessage(run.pausing), canCancel: pauseIsHarnessScoped)
    case "updating" where waitsForItsTurn(harness, run: run):
      HarnessUpdateStatus(isActive: true, message: "Waiting to update…", canCancel: false)
    case "continuing":
      HarnessUpdateStatus(isActive: true, message: "Continuing chats…", canCancel: false)
    default:
      nil
    }
  }

  private static func lifecycleStatus(_ harness: ServerHarness) -> HarnessUpdateStatus {
    guard isUpdating(harness) else { return .idle }

    let message = harness.lifecycle?.targetVersion.map { "Updating to \($0)…" } ?? "Updating…"
    return HarnessUpdateStatus(isActive: true, message: message, canCancel: false)
  }

  private static func waitsForItsTurn(_ harness: ServerHarness, run: ServerUpdateRunState) -> Bool {
    run.currentHarnessId != harness.id && isUpdating(harness)
  }

  private static func isUpdating(_ harness: ServerHarness) -> Bool {
    ["installing", "updating", "pendingUpdate"].contains(harness.lifecycle?.phase ?? "")
  }

  private static func pausingMessage(_ chats: Int) -> String {
    switch chats {
    case 0: "Pausing chats…"
    case 1: "Pausing 1 chat…"
    default: "Pausing \(chats) chats…"
    }
  }
}
