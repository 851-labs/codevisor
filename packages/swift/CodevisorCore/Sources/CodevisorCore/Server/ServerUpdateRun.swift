import Foundation

@MainActor
final class ServerUpdateRun {
  struct Machine {
    let beginWaiting: @MainActor () -> Void
    let markReady: @MainActor () -> Void
    let markFailed: @MainActor (_ message: String) -> Void
    let scheduleRecovery: @MainActor () -> Void
    let resumeEventStream: @MainActor () -> Void
    let refreshStatus: @MainActor () async -> Void
    let refreshNavigation: @MainActor () async -> Void
    let probeDataUpgrade: @MainActor () async -> ServerHealth?
  }

  enum Step {
    case proceed
    case retry
    case finished
  }

  nonisolated static let dataUpgradeFailureMessage = "The server couldn't finish updating its data."
  private nonisolated static let drainingStatusMessage = "Pausing chats for the update…"
  private nonisolated static let dataUpgradeFallbackStatus = "Updating server data…"

  private let connection: MachineConnection
  private let client: any CodevisorServerClienting
  private let channel: ServerUpdateChannel
  private let machine: Machine
  private let scheduler: ServerUpdateScheduler
  private let pollInterval: Duration
  private let pollAttempts: Int
  private let initialVersion: String?
  private var initialHealth: ServerHealth?

  init(
    connection: MachineConnection,
    client: any CodevisorServerClienting,
    channel: ServerUpdateChannel,
    machine: Machine,
    scheduler: ServerUpdateScheduler,
    pollInterval: Duration,
    pollAttempts: Int
  ) {
    self.connection = connection
    self.client = client
    self.channel = channel
    self.machine = machine
    self.scheduler = scheduler
    self.pollInterval = pollInterval
    self.pollAttempts = pollAttempts
    initialVersion = connection.updateInfo?.currentVersion
  }

  func perform() async {
    showStarting()
    defer { clearActivity() }
    machine.beginWaiting()
    initialHealth = try? await client.health()
    do {
      let applied = try await client.applyServerUpdate(channel: channel)
      guard applied.accepted else { return await finishDeclined(applied) }

      await waitForUpdatedServer(applied)
    } catch {
      await finishRejected(error)
    }
  }

  static func notConvergedMessage(
    initial: ServerHealth?, current: ServerHealth?, refreshed: ServerUpdateInfo?
  ) -> String {
    guard restarted(from: initial, to: current) else {
      return "The server is still running the previous version and never restarted. Check it on the machine directly."
    }

    let installed = installedVersion(current: current, refreshed: refreshed)
    let latest = refreshed?.latestVersion ?? "a newer release"
    return "The server restarted into \(installed), but \(latest) is still available. Try updating again."
  }

  private var versionBeforeUpdate: String? {
    initialVersion ?? initialHealth?.version
  }

  private func showStarting() {
    connection.updatePhase = .updating
    connection.updateProgress = nil
    connection.updateStatusMessage = nil
  }

  private func clearActivity() {
    connection.updateStatusMessage = nil
    connection.updateProgress = nil
  }

  private func finishDeclined(_ applied: ServerUpdateApplied) async {
    machine.markReady()
    machine.resumeEventStream()
    if applied.reason == "busy" {
      connection.updatePhase = .failed(
        "This server still has chats running. Wait for them to finish, then update."
      )
      return
    }

    await machine.refreshStatus()
    connection.updatePhase = .idle
  }

  private func finishRejected(_ error: any Error) async {
    let message = serverErrorMessage(error)
    connection.updatePhase = .failed(message)
    guard await serverAnswers() else {
      machine.markFailed(message)
      machine.scheduleRecovery()
      return
    }

    machine.markReady()
    machine.resumeEventStream()
  }

  private func waitForUpdatedServer(_ applied: ServerUpdateApplied) async {
    let initialApplyAt = connection.updateInfo?.lastApply?.at
    if applied.draining == true {
      connection.updateStatusMessage = Self.drainingStatusMessage
    }
    var wait = ServerUpdateWait(
      applied: applied,
      initialApplyAt: initialApplyAt,
      scheduler: scheduler,
      budget: pollInterval * pollAttempts
    )
    while wait.hasTimeLeft {
      try? await scheduler.sleep(pollInterval)
      if await poll(&wait) == .finished { return }
    }
    await finishTimedOut()
  }

  private func poll(_ wait: inout ServerUpdateWait) async -> Step {
    let reportStep = await followApplyReport(&wait)
    guard reportStep == .proceed else { return reportStep }

    let upgradeStep = await followDataUpgrade(&wait)
    guard upgradeStep == .proceed else { return upgradeStep }

    return await checkRestartedServer(wait)
  }

  private func followApplyReport(_ wait: inout ServerUpdateWait) async -> Step {
    let update = try? await client.updateInfo(refresh: false, channel: channel)
    guard let report = update?.lastApply, wait.isFresh(report) else { return .proceed }

    switch report.state {
    case "failed":
      failOnMachine(report)
      return .finished
    case "draining":
      showDraining(report, wait: &wait)
      return .retry
    case "installing":
      showInstalling(report, wait: &wait)
      return .proceed
    default:
      return .proceed
    }
  }

  private func failOnMachine(_ report: ServerUpdateApplyState) {
    connection.updatePhase = .failed(report.message ?? "The update failed on the machine.")
    machine.markReady()
    machine.resumeEventStream()
  }

  private func showDraining(_ report: ServerUpdateApplyState, wait: inout ServerUpdateWait) {
    connection.updateProgress = nil
    connection.updateStatusMessage = report.message ?? Self.drainingStatusMessage
    wait.extendDeadline()
  }

  private func showInstalling(_ report: ServerUpdateApplyState, wait: inout ServerUpdateWait) {
    let progress = Self.installProgress(report.progress)
    let message = report.message ?? "Installing…"
    wait.noteInstall(progress: progress, message: message)
    connection.updateProgress = progress
    connection.updateStatusMessage = message
    wait.followInstallTarget(report.targetBuildNumber)
  }

  private func followDataUpgrade(_ wait: inout ServerUpdateWait) async -> Step {
    guard let health = await machine.probeDataUpgrade() else { return .proceed }

    let migration = connection.dataUpgradeProgress
    if health.database == "failed" {
      failDataUpgrade(migration)
      return .finished
    }

    wait.noteMigration()
    connection.updateProgress = migration?.fractionCompleted
    connection.updateStatusMessage = Self.dataUpgradeStatus(migration)
    return .retry
  }

  private func failDataUpgrade(_ migration: ServerMigrationProgress?) {
    let message = migration?.error ?? Self.dataUpgradeFailureMessage
    connection.updatePhase = .failed(message)
    machine.markFailed(message)
  }

  private func checkRestartedServer(_ wait: ServerUpdateWait) async -> Step {
    guard let info = try? await client.info() else {
      showRestarting()
      return .retry
    }
    guard await hasConverged(info, wait: wait) else { return .retry }

    await finishConverged()
    return .finished
  }

  private func showRestarting() {
    connection.updateProgress = nil
    connection.updateStatusMessage = "Restarting…"
  }

  private func hasConverged(_ info: ServerInfo, wait: ServerUpdateWait) async -> Bool {
    if let targetBuild = wait.targetBuildNumber,
      let currentBuild = (try? await client.health())?.buildNumber
    {
      return currentBuild >= targetBuild
    }

    return await hasConvergedOnVersion(info, wait: wait)
  }

  private func hasConvergedOnVersion(_ info: ServerInfo, wait: ServerUpdateWait) async -> Bool {
    let reachedTarget = wait.reachedTargetVersion(info.version)
    let restarted = await hasRestarted(into: info)
    if reachedTarget { return true }
    guard restarted else { return false }

    return await requestedChannelIsCurrent()
  }

  private func hasRestarted(into info: ServerInfo) async -> Bool {
    if let before = versionBeforeUpdate, info.version != before { return true }
    guard let initialBootId = initialHealth?.bootId else { return false }
    guard let currentBootId = (try? await client.health())?.bootId else { return false }

    return currentBootId != initialBootId
  }

  private func requestedChannelIsCurrent() async -> Bool {
    guard let refreshed = try? await client.updateInfo(refresh: true, channel: channel) else { return false }

    return !refreshed.updateAvailable
  }

  private func finishConverged() async {
    connection.updatePhase = .idle
    machine.markReady()
    await machine.refreshStatus()
    await machine.refreshNavigation()
    machine.resumeEventStream()
  }

  private func finishTimedOut() async {
    guard await serverAnswers() else { return reportServerNeverReturned() }

    await finishUnconverged()
  }

  private func reportServerNeverReturned() {
    let message = "The server did not come back after updating. Check it on the machine directly."
    connection.updatePhase = .failed(message)
    machine.markFailed(message)
    machine.scheduleRecovery()
  }

  private func finishUnconverged() async {
    machine.markReady()
    let refreshed = try? await client.updateInfo(refresh: true, channel: channel)
    if let refreshed { connection.updateInfo = refreshed }
    await machine.refreshStatus()
    machine.resumeEventStream()
    guard refreshed?.updateAvailable != false else {
      connection.updatePhase = .idle
      await machine.refreshNavigation()
      return
    }

    connection.updatePhase = .failed(
      Self.notConvergedMessage(initial: initialHealth, current: try? await client.health(), refreshed: refreshed))
  }

  private func serverAnswers() async -> Bool {
    (try? await client.info()) != nil
  }

  private nonisolated static func installProgress(_ reported: Double?) -> Double? {
    guard let reported, reported.isFinite else { return nil }

    return min(1, max(0, reported))
  }

  private nonisolated static func dataUpgradeStatus(_ migration: ServerMigrationProgress?) -> String {
    guard let name = migration?.name, !name.isEmpty else { return dataUpgradeFallbackStatus }

    return name
  }

  private nonisolated static func restarted(from initial: ServerHealth?, to current: ServerHealth?) -> Bool {
    bootChanged(from: initial, to: current) || buildAdvanced(from: initial, to: current)
  }

  private nonisolated static func bootChanged(from initial: ServerHealth?, to current: ServerHealth?) -> Bool {
    guard let before = initial?.bootId, let after = current?.bootId else { return false }

    return before != after
  }

  private nonisolated static func buildAdvanced(from initial: ServerHealth?, to current: ServerHealth?) -> Bool {
    guard let before = initial?.buildNumber, let after = current?.buildNumber else { return false }

    return after > before
  }

  private static func installedVersion(current: ServerHealth?, refreshed: ServerUpdateInfo?) -> String {
    guard let refreshed else { return current?.version ?? "a different version" }

    return AppUpdateModel.displayedVersion(
      refreshed.currentVersion,
      buildNumber: refreshed.currentBuildNumber,
      usesAlphaChannel: refreshed.channel == "alpha"
    )
  }
}
