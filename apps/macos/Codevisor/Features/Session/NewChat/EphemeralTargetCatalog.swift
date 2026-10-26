import CodevisorCore
import Observation

@Observable
final class EphemeralTargetCatalog {
  private(set) var targets: [EphemeralTarget] = []

  func load(from client: any CodevisorServerClienting) async {
    let providers = (try? await client.ephemeralProviders()) ?? []
    targets = providers.filter(\.configured).map { EphemeralTarget.provider($0.id) }
  }
}
