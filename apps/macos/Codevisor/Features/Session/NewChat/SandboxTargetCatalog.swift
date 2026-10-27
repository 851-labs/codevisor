import CodevisorCore
import Observation

@Observable
final class SandboxTargetCatalog {
  private(set) var targets: [SandboxTarget] = []

  func load(from client: any CodevisorServerClienting) async {
    let providers = (try? await client.sandboxProviders()) ?? []
    targets = providers.filter(\.configured).map { SandboxTarget.provider($0.id) }
  }
}
