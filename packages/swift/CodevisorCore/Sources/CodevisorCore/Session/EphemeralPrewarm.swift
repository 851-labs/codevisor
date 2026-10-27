import CodevisorClient
import Foundation

@MainActor
final class EphemeralPrewarm {
  struct Key: Equatable {
    let target: EphemeralTarget
    let projectId: UUID
  }

  let key: Key
  let machineId: String
  private let client: any CodevisorServerClienting
  private var creation: Task<Result<Void, any Error>, Never>?
  private var follow: Task<Void, Never>?
  private var buffered: [EphemeralSetupLogLine] = []
  private weak var tracker: EphemeralSetupTracker?
  private static let bufferLimit = 2000

  init(key: Key, harnessId: String?, client: any CodevisorServerClienting) {
    self.key = key
    self.client = client
    machineId = UUID().uuidString.lowercased()
    let log = EphemeralSetupLogLine.liveLog(client, machineId: machineId)
    follow = Task { [weak self] in
      for await line in log { self?.receive(line) }
    }
    let request = ServerEphemeralMachineRequest(
      id: machineId, provider: key.target.providerId, projectId: key.projectId,
      workspaceId: nil, harnessId: harnessId)
    creation = Task { await Self.create(request, client: client) }
  }

  func created() async throws {
    try await creation?.value.get()
  }

  func attach(_ tracker: EphemeralSetupTracker) {
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
      try? await client.destroyEphemeralMachine(id: machineId)
    }
  }

  private func receive(_ line: EphemeralSetupLogLine) {
    if let tracker {
      tracker.append(line)
      return
    }
    buffered.append(line)
    if buffered.count > Self.bufferLimit { buffered.removeFirst(buffered.count - Self.bufferLimit) }
  }

  private static func create(
    _ request: ServerEphemeralMachineRequest,
    client: any CodevisorServerClienting
  ) async -> Result<Void, any Error> {
    do {
      _ = try await client.createEphemeralMachine(request)
      return .success(())
    } catch {
      return .failure(error)
    }
  }
}
