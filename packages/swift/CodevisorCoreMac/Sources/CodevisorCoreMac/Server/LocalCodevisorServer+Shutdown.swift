import CodevisorCore
import Foundation

extension LocalCodevisorServer {
  /// How long the app waits for the server's live chats to finish before
  /// asking the server to interrupt them. The server has its own deadline;
  /// this one only guards against a server that never reports drained.
  static let appUpdateDrainTimeout: Duration = .seconds(15 * 60)
  static let appUpdateDrainPollInterval: Duration = .seconds(1)

  /// Drains live chats, stops launchd ownership before Sparkle replaces the
  /// bundle, then waits for the old runtime to release its executable and
  /// database lease. The drain snapshots the live sessions so the updated
  /// server brings them back and dispatches any prompts held meanwhile.
  @discardableResult
  public func prepareForAppUpdate(
    onStatus: @escaping @MainActor (String) -> Void = { _ in }
  ) async -> Bool {
    preparingForUpdate = true
    if let ensureTask {
      ensureTask.cancel()
      guard (try? await StartupDeadline.run(for: .seconds(20), operation: { await ensureTask.value })) != nil else {
        return false
      }
    }
    var clock = StepClock()
    lifecycleLog.note("prepareForAppUpdate: begin")
    updateRequestMonitor?.cancel()
    updateRequestMonitor = nil
    updateRequestSource?.cancel()
    updateRequestSource = nil
    guard await drainForAppUpdate(onStatus: onStatus) else {
      lifecycleLog.error("Update cancelled: server drain did not finish before its final deadline")
      return false
    }
    lifecycleLog.note("prepareForAppUpdate: drain finished (\(clock.lap()) ms)")
    let stopped = await shutdown()
    lifecycleLog.note(
      "prepareForAppUpdate: server \(stopped ? "stopped" : "NOT stopped") (\(clock.lap()) ms, \(clock.totalMilliseconds) ms total)"
    )
    return stopped
  }

  /// Asks the server to drain and polls until it reports drained. A server
  /// that cannot answer (already gone, or predating the drain) is treated as
  /// drained: the shutdown that follows behaves exactly as before.
  func drainForAppUpdate(
    onStatus: @escaping @MainActor (String) -> Void,
    drainTimeout: Duration = appUpdateDrainTimeout,
    interruptionTimeout: Duration = .seconds(15),
    pollInterval: Duration = appUpdateDrainPollInterval,
    scheduler: LocalServerScheduler = .continuous
  ) async -> Bool {
    guard
      let first = try? await StartupDeadline.run(
        for: .seconds(5), scheduler: scheduler,
        operation: { [client] in try await client.beginRestartDrain(interrupt: false) })
    else {
      lifecycleLog.note("prepareForAppUpdate: server has no restart drain (or is not answering)")
      return true
    }
    lifecycleLog.note("prepareForAppUpdate: drain \(first.state), \(first.remaining) live turn(s)")
    if first.isDrained { return true }
    let deadline = scheduler.now() + drainTimeout
    let finalDeadline = deadline + interruptionTimeout
    var interrupted = false
    while true {
      guard !Task.isCancelled, scheduler.now() < finalDeadline else { return false }
      guard
        let state = try? await StartupDeadline.run(
          for: min(.seconds(3), finalDeadline - scheduler.now()), scheduler: scheduler,
          operation: { [client] in try await client.restartDrainState() })
      else { return false }
      if state.isDrained { return true }
      let chats = state.remaining == 1 ? "1 chat" : "\(state.remaining) chats"
      onStatus("Waiting for \(chats) to finish…")
      if scheduler.now() >= deadline, !interrupted {
        interrupted = true
        lifecycleLog.note("prepareForAppUpdate: drain deadline reached, interrupting live turns")
        _ = try? await StartupDeadline.run(
          for: min(.seconds(5), finalDeadline - scheduler.now()), scheduler: scheduler
        ) { [client] in
          try await client.beginRestartDrain(interrupt: true)
        }
      }
      do { try await scheduler.sleep(pollInterval) } catch { return false }
    }
  }

  public func abandonAppUpdate() async {
    preparingForUpdate = false
    lifecycleLog.note("abandonAppUpdate: releasing the drain")
    _ = try? await StartupDeadline.run(for: .seconds(3)) { [client] in try await client.cancelRestartDrain() }
    if await isHealthy() {
      startUpdateRequestMonitor()
      return
    }
    // The server was already stopped for the update: bring it back so the
    // app is usable again without a relaunch.
    lifecycleLog.note("abandonAppUpdate: server is down; starting it again")
    await ensureRunning()
  }

  /// Stops the running local server so a newer bundled runtime can take over
  /// on the next launch. Asks politely over HTTP first (the server may not be
  /// a process we own), then force-terminates any owned process that lingers.
  @discardableResult
  public func shutdown() async -> Bool {
    let owner = ServerProcessOwnership.owner(databasePath: databasePath)
    do {
      try await StartupDeadline.run(for: .seconds(3)) { [client] in try await client.requestShutdown() }
      lifecycleLog.note("shutdown: server acknowledged the shutdown request")
    } catch {
      lifecycleLog.note("shutdown: request not answered; checking process ownership")
    }
    if let managedService {
      do { try await managedService.stop() } catch {
        lifecycleLog.error("shutdown: background service could not be stopped: \(error.localizedDescription)")
        return false
      }
    }
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(10)
    try? await Task.sleep(for: .milliseconds(400))
    var signalled = false
    while !Task.isCancelled, clock.now < deadline {
      let stopped: Bool
      if let shutdownProbe {
        stopped = await shutdownProbe()
      } else {
        if process?.isRunning == true {
          stopped = false
        } else {
          stopped = await ServerProcessOwnership.hasStopped(
            port: port, databasePath: databasePath, previousOwner: owner)
        }
      }
      if stopped {
        finishShutdown()
        return true
      }
      if !signalled {
        signalled = true
        if let process, process.isRunning { process.terminate() }
        if let staleListenerTerminator {
          await staleListenerTerminator(port)
        } else {
          await ServerProcessOwnership.terminate(owner, databasePath: databasePath)
        }
      }
      try? await Task.sleep(for: .milliseconds(200))
    }
    lifecycleLog.error("shutdown: the old server still owns its process, port, or database lease")
    return false
  }

  private func finishShutdown() {
    process = nil
    activeBootId = nil
    dataUpgradeProgress = nil
    state = .idle
    lifecycleLog.note("shutdown: server is down")
  }
}
