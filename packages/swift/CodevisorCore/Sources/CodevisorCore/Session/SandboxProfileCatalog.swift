import CodevisorClient
import Foundation
import Observation

public struct SandboxProfileChoice: Equatable, Identifiable, Sendable {
  public let target: SandboxTarget
  public let disabledReason: String?

  public var id: String { target.id }
  public var isEnabled: Bool { disabledReason == nil }

  public init(target: SandboxTarget, disabledReason: String? = nil) {
    self.target = target
    self.disabledReason = disabledReason
  }
}

@MainActor
@Observable
public final class SandboxProfileCatalog {
  public private(set) var choices: [SandboxProfileChoice] = []

  public init() {}

  public func load(
    from composer: any CodevisorServerClienting,
    host: (String) -> (any CodevisorServerClienting)?
  ) async {
    let providers = (try? await composer.sandboxProviders()) ?? ServerSandboxProviders()
    let profiles = (try? await composer.sandboxProfiles()) ?? []
    let targets = profiles.map { SandboxTarget(profile: $0, provider: providers.provider($0.provider)) }
    let reasons = await disabledReasons(for: targets, composer: composer, host: host)
    choices = targets.map { SandboxProfileChoice(target: $0, disabledReason: reasons[$0.profileId]) }
  }

  private func disabledReasons(
    for targets: [SandboxTarget],
    composer: any CodevisorServerClienting,
    host: (String) -> (any CodevisorServerClienting)?
  ) async -> [String: String] {
    var reasons: [String: String] = [:]
    let local = await availability(from: composer)
    for target in targets {
      reasons[target.profileId] = await reason(for: target, local: local, host: host)
    }
    return reasons
  }

  private func reason(
    for target: SandboxTarget,
    local: [String: String?],
    host: (String) -> (any CodevisorServerClienting)?
  ) async -> String? {
    guard let hostMachineId = target.hostMachineId else { return local[target.profileId] ?? nil }
    guard let hostClient = host(hostMachineId) else { return "Its Mac isn't connected" }
    return await availability(from: hostClient)[target.profileId] ?? nil
  }

  private func availability(from client: any CodevisorServerClienting) async -> [String: String?] {
    let entries = (try? await client.sandboxAvailability()) ?? []
    return Dictionary(entries.map { ($0.profileId, $0.disabledReason) }, uniquingKeysWith: { first, _ in first })
  }
}
