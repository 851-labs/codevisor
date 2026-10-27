import CodevisorClient
import Foundation

@MainActor
final class SandboxPrewarm {
  struct Key: Equatable {
    let target: SandboxTarget
    let projectId: UUID
  }

  let key: Key
  let machineId: String
  let client: any CodevisorServerClienting
  private var creation: Task<Result<Void, any Error>, Never>?
  private var follow: Task<Void, Never>?
  private var buffered: [SandboxSetupLogLine] = []
  private weak var tracker: SandboxSetupTracker?
  private static let bufferLimit = 2000

  init(key: Key, project: Project, harnessId: String?, client: any CodevisorServerClienting) {
    self.key = key
    self.client = client
    machineId = UUID().uuidString.lowercased()
    let log = SandboxSetupLogLine.liveLog(client, machineId: machineId)
    follow = Task { [weak self] in
      for await line in log { self?.receive(line) }
    }
    let request = ServerSandboxRequest(
      id: machineId, profileId: key.target.profileId, projectId: key.projectId,
      projectName: project.name, repoUrl: project.repoUrl, workspaceId: nil, harnessId: harnessId)
    creation = Task { await Self.create(request, client: client) }
  }

  func created() async throws {
    try await creation?.value.get()
  }

  func attach(_ tracker: SandboxSetupTracker) {
    self.tracker = tracker
    buffered.forEach(tracker.append)
    buffered = []
  }

  func finish() {
    follow?.cancel()
  }

  func abandon() {
    finish()
    let creation = creation
    let client = client
    let machineId = machineId
    Task {
      _ = await creation?.value
      try? await client.destroySandbox(id: machineId)
    }
  }

  private func receive(_ line: SandboxSetupLogLine) {
    if let tracker {
      tracker.append(line)
      return
    }
    buffered.append(line)
    if buffered.count > Self.bufferLimit { buffered.removeFirst(buffered.count - Self.bufferLimit) }
  }

  private static func create(
    _ request: ServerSandboxRequest,
    client: any CodevisorServerClienting
  ) async -> Result<Void, any Error> {
    do {
      _ = try await client.createSandbox(request)
      return .success(())
    } catch {
      return .failure(error)
    }
  }
}
