import Foundation

public extension CodevisorServerClienting {
  func ephemeralProviders() async throws -> [ServerEphemeralProvider] {
    []
  }

  func createEphemeralMachine(provider: String, projectId: UUID) async throws -> ServerEphemeralMachine {
    throw CodevisorServerClientError.invalidResponse
  }
}
