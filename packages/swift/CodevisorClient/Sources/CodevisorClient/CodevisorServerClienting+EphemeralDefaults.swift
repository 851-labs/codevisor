import Foundation

public extension CodevisorServerClienting {
  func ephemeralProviders() async throws -> [ServerEphemeralProvider] {
    []
  }

  func ephemeralMachines() async throws -> [ServerEphemeralMachine] {
    []
  }

  func destroyEphemeralMachine(id: String) async throws {}

  func createEphemeralMachine(_ request: ServerEphemeralMachineRequest) async throws -> ServerEphemeralMachine {
    throw CodevisorServerClientError.invalidResponse
  }

  func claimEphemeralWorkspace(id: String, workspaceId: UUID) async throws -> ServerEphemeralMachine {
    throw CodevisorServerClientError.invalidResponse
  }
}
