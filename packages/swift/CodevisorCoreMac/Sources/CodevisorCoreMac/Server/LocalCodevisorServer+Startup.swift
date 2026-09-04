import CodevisorCore
import Foundation

extension LocalCodevisorServer {
  func startManagedServer(_ service: LocalCodevisorManagedService) async -> LocalCodevisorServerState {
    for attempt in 0..<2 {
      guard !Task.isCancelled else { return .unavailable("Server startup was cancelled.") }
      startupAttemptStartedAt = Date()
      activeBootId = nil
      startupCanRetry = false
      dataUpgradeProgress = nil
      startupProgress = LocalServerStartupProgress(stage: "preparingService", completed: 0)
      startupStep = "register managed service"
      do {
        try await service.start()
      } catch {
        let message = "Codevisor's background server could not be started: \(error.localizedDescription)"
        lifecycleLog.error(message)
        state = .unavailable(message)
        captureStartupDiagnostics(message)
        return state
      }
      startupProgress = LocalServerStartupProgress(stage: "startingProcess", completed: 1)
      startUpdateRequestMonitor()
      startupStep = "wait for managed server"
      let result = await waitUntilHealthy(
        process: nil, expectedBootId: nil, requiresBundledIdentity: true,
        initialAttemptLimit: managedStartupPollAttempts,
        jobProbe: service.isJobRunning
      )
      guard case let .unavailable(message) = result else { return result }
      captureStartupDiagnostics(message)
      guard attempt == 0, startupCanRetry, !Task.isCancelled else { return result }
      lifecycleLog.note("startup recovery: restarting the managed service once")
      guard await shutdown() else {
        state = .unavailable("Codevisor could not stop the previous server. See the server log for recovery details.")
        return state
      }
    }
    return state
  }

  func completeStartup() {
    var progress = startupProgress ?? LocalServerStartupProgress(stage: "ready", completed: 7)
    progress.stage = "ready"
    progress.completed = 7
    progress.state = "ready"
    progress.work = nil
    startupProgress = progress
  }

  /// Only fresh, boot-scoped checkpoints can describe or extend this attempt.
  func refreshStartupProgress(expectedBootId: String?) -> Bool {
    guard let data = try? Data(contentsOf: startupStatusURL),
      let next = try? JSONDecoder().decode(LocalServerStartupProgress.self, from: data),
      next.belongsToAttempt(startedAfter: startupAttemptStartedAt, expectedBootId: expectedBootId)
    else { return false }
    if let current = startupProgress, !current.bootId.isEmpty {
      guard current.bootId == next.bootId, next.stageOrder >= current.stageOrder, next.updatedAt >= current.updatedAt
      else { return false }
      if current.work?.id == next.work?.id,
        let before = current.work?.completed, let after = next.work?.completed, after < before
      {
        return false
      }
    }
    let advanced = next.progressKey != startupProgress?.progressKey
    startupProgress = next
    activeBootId = next.bootId
    return advanced
  }

  func captureStartupDiagnostics(_ message: String) {
    struct Diagnostic: Encodable {
      var capturedAt: Date
      var stage: String?
      var message: String
      var progress: LocalServerStartupProgress?
    }
    let diagnostic = Diagnostic(capturedAt: Date(), stage: startupStep, message: message, progress: startupProgress)
    let directory = logURL.deletingLastPathComponent()
    let path = directory.appendingPathComponent("startup-failure-\(UUID().uuidString).json")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try JSONEncoder().encode(diagnostic).write(to: path, options: .atomic)
      lifecycleLog.error("Startup diagnostics saved to \(path.path)")
      // Keep diagnostics bounded across repeated failed updates.
      let files = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
      )
      .filter { $0.lastPathComponent.hasPrefix("startup-failure-") && $0.pathExtension == "json" }
      .sorted {
        let first =
          (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let second =
          (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return first > second
      }
      for file in files.dropFirst(5) { try? FileManager.default.removeItem(at: file) }
    } catch {
      lifecycleLog.error("Could not save startup diagnostics: \(error.localizedDescription)")
    }
  }
}
