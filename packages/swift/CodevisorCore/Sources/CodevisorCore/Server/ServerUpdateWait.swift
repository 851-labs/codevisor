import Foundation

@MainActor
struct ServerUpdateWait {
  nonisolated static let migrationMaximumDuration: Duration = .seconds(10 * 60)

  let targetVersion: String?
  private(set) var targetBuildNumber: Int?
  private let initialApplyAt: String?
  private let scheduler: ServerUpdateScheduler
  private let budget: Duration
  private var deadline: ContinuousClock.Instant
  private var lastInstallProgress: Double?
  private var lastInstallMessage: String?
  private var migrationStartedAt: ContinuousClock.Instant?

  init(
    applied: ServerUpdateApplied,
    initialApplyAt: String?,
    scheduler: ServerUpdateScheduler,
    budget: Duration
  ) {
    targetVersion = applied.targetVersion
    targetBuildNumber = applied.targetBuildNumber
    self.initialApplyAt = initialApplyAt
    self.scheduler = scheduler
    self.budget = budget
    deadline = scheduler.now() + budget
  }

  var hasTimeLeft: Bool {
    scheduler.now() < deadline
  }

  nonisolated func isFresh(_ report: ServerUpdateApplyState) -> Bool {
    report.at != initialApplyAt || report.state == "draining"
  }

  nonisolated func reachedTargetVersion(_ version: String) -> Bool {
    targetVersion == nil || version == targetVersion
  }

  mutating func extendDeadline() {
    deadline = max(deadline, scheduler.now() + budget)
  }

  mutating func noteInstall(progress: Double?, message: String) {
    if isNewInstallReport(progress: progress, message: message) { extendDeadline() }
    lastInstallProgress = progress
    lastInstallMessage = message
  }

  mutating func followInstallTarget(_ buildNumber: Int?) {
    guard let buildNumber, buildNumber != targetBuildNumber else { return }

    targetBuildNumber = buildNumber
    extendDeadline()
  }

  mutating func noteMigration() {
    let startedAt = migrationStartedAt ?? scheduler.now()
    migrationStartedAt = startedAt
    guard scheduler.now() - startedAt < Self.migrationMaximumDuration else { return }

    extendDeadline()
  }

  private nonisolated func isNewInstallReport(progress: Double?, message: String) -> Bool {
    progress != lastInstallProgress || message != lastInstallMessage
  }
}
