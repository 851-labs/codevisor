import Foundation

public extension CodevisorServerClienting {
  func sandboxVendors() async throws -> ServerSandboxVendors {
    ServerSandboxVendors()
  }

  func sandboxProviders() async throws -> [ServerSandboxProvider] {
    []
  }

  func createSandboxProvider(_ request: ServerSandboxProviderRequest) async throws -> ServerSandboxProvider {
    throw CodevisorServerClientError.invalidResponse
  }

  func updateSandboxProvider(id: String, _ request: ServerSandboxProviderRequest) async throws -> ServerSandboxProvider
  {
    throw CodevisorServerClientError.invalidResponse
  }

  func deleteSandboxProvider(id: String) async throws {}

  func deleteSandboxProviderAndProfiles(id: String) async throws {}

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

  func wakeSandbox(id: String) async throws -> ServerSandbox {
    throw CodevisorServerClientError.invalidResponse
  }

  func createSandbox(_ request: ServerSandboxRequest) async throws -> ServerSandbox {
    throw CodevisorServerClientError.invalidResponse
  }

  func claimSandboxWorkspace(id: String, workspaceId: UUID) async throws -> ServerSandbox {
    throw CodevisorServerClientError.invalidResponse
  }
}
