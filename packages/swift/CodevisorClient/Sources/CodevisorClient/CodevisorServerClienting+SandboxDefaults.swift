import Foundation

public extension CodevisorServerClienting {
  func sandboxProviders() async throws -> ServerSandboxProviders {
    ServerSandboxProviders()
  }

  func sandboxAccounts() async throws -> [ServerSandboxAccount] {
    []
  }

  func createSandboxAccount(_ request: ServerSandboxAccountRequest) async throws -> ServerSandboxAccount {
    throw CodevisorServerClientError.invalidResponse
  }

  func updateSandboxAccount(id: String, _ request: ServerSandboxAccountRequest) async throws -> ServerSandboxAccount {
    throw CodevisorServerClientError.invalidResponse
  }

  func deleteSandboxAccount(id: String) async throws {}

  func sandboxProfiles() async throws -> [ServerSandboxProfile] {
    []
  }

  func createSandboxProfile(_ request: ServerSandboxProfileRequest) async throws -> ServerSandboxProfile {
    throw CodevisorServerClientError.invalidResponse
  }

  func updateSandboxProfile(id: String, _ request: ServerSandboxProfileRequest) async throws -> ServerSandboxProfile {
    throw CodevisorServerClientError.invalidResponse
  }

  func deleteSandboxProfile(id: String) async throws {}

  func sandboxAvailability() async throws -> [ServerSandboxAvailability] {
    []
  }

  func sandboxes() async throws -> [ServerSandbox] {
    []
  }

  func destroySandbox(id: String) async throws {}

  func createSandbox(_ request: ServerSandboxRequest) async throws -> ServerSandbox {
    throw CodevisorServerClientError.invalidResponse
  }

  func claimSandboxWorkspace(id: String, workspaceId: UUID) async throws -> ServerSandbox {
    throw CodevisorServerClientError.invalidResponse
  }
}
