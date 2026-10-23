import Foundation

public struct ServerEphemeralProvider: Decodable, Equatable, Sendable, Identifiable {
  public var id: String
  public var displayName: String
  public var configured: Bool

  public init(id: String, displayName: String, configured: Bool) {
    self.id = id
    self.displayName = displayName
    self.configured = configured
  }
}

public struct ServerEphemeralMachine: Decodable, Equatable, Sendable, Identifiable {
  public var id: String
  public var provider: String
  public var name: String
  public var state: String
  public var error: String?
}

private struct EphemeralProvidersResponse: Decodable {
  var providers: [ServerEphemeralProvider]
}

private struct CreateEphemeralMachineBody: Encodable {
  var provider: String
  var projectId: String
}

private struct CreateEphemeralMachineResponse: Decodable {
  var machine: ServerEphemeralMachine
}

extension CodevisorServerClient {
  public func ephemeralProviders() async throws -> [ServerEphemeralProvider] {
    let response: EphemeralProvidersResponse = try await get("/v1/ephemeral-providers")
    return response.providers
  }

  public func createEphemeralMachine(provider: String, projectId: UUID) async throws -> ServerEphemeralMachine {
    let response: CreateEphemeralMachineResponse = try await send(
      "/v1/ephemeral-machines",
      method: "POST",
      body: CreateEphemeralMachineBody(provider: provider, projectId: projectId.uuidString)
    )
    return response.machine
  }
}
