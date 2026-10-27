import CodevisorClient
import Foundation

public struct SandboxMachine: Sendable {
  public let name: String
  public let client: any CodevisorServerClienting

  public init(name: String, client: any CodevisorServerClienting) {
    self.name = name
    self.client = client
  }
}
