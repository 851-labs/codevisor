import CodevisorClient

@MainActor
final class FirstRunStatusFeed {
  private let client: any CodevisorServerClienting
  private var latest: ServerFirstRunStatus?
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var following: Task<Void, Never>?

  init(client: any CodevisorServerClienting) {
    self.client = client
  }

  func status(where isEnough: (ServerFirstRunStatus) -> Bool) async throws -> ServerFirstRunStatus {
    startFollowing()
    while true {
      try Task.checkCancellation()
      if let latest, isEnough(latest) { return latest }
      await nextUpdate()
    }
  }

  private func startFollowing() {
    guard following == nil else { return }
    following = Task { await follow() }
  }

  private func follow() async {
    do {
      let cursor = try await client.latestShellEventCursor()
      apply(try await client.firstRunStatus())
      let events = client.shellEventStream(since: cursor, handledKinds: [ServerFirstRunStatus.eventKind])
      for try await event in events {
        if let status = ServerFirstRunStatus.from(event) { apply(status) }
      }
    } catch {
      apply(ServerFirstRunStatus(state: .failed, harnesses: latest?.harnesses))
    }
  }

  private func apply(_ status: ServerFirstRunStatus) {
    guard Self.progress(of: status) > Self.progress(of: latest) else { return }
    latest = status
    let waiting = waiters
    waiters = []
    waiting.forEach { $0.resume() }
  }

  private func nextUpdate() async {
    await withCheckedContinuation { waiters.append($0) }
  }

  private static func progress(of status: ServerFirstRunStatus?) -> FirstRunProgress {
    guard let status else { return FirstRunProgress(stage: 0, addedProjects: 0) }
    return FirstRunProgress(stage: stage(of: status), addedProjects: status.projects?.count ?? 0)
  }

  private static func stage(of status: ServerFirstRunStatus) -> Int {
    if status.isFinal { return 3 }
    return status.harnesses == nil ? 1 : 2
  }
}
