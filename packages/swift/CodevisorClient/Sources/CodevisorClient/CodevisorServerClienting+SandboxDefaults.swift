import Foundation

public extension CodevisorServerClienting {
  func sandboxProviders() async throws -> [ServerSandboxProvider] {
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
