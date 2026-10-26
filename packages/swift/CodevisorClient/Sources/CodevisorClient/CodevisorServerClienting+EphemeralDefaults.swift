import Foundation

public extension CodevisorServerClienting {
  func ephemeralProviders() async throws -> [ServerEphemeralProvider] {
    []
  }

  func ephemeralMachines() async throws -> [ServerEphemeralMachine] {
    []
  }

  func destroyEphemeralMachine(id: String) async throws {}

  func createEphemeralMachine(
    id: String,
    provider: String,
    projectId: UUID,
    workspaceId: UUID?
  ) async throws -> ServerEphemeralMachine {
    throw CodevisorServerClientError.invalidResponse
  }
}
