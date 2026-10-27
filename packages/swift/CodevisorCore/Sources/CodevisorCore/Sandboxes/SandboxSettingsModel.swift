import CodevisorClient
import Foundation
import Observation

@MainActor
@Observable
public final class SandboxSettingsModel {
  public private(set) var providers = ServerSandboxProviders()
  public private(set) var accounts: [ServerSandboxAccount] = []
  public private(set) var profiles: [ServerSandboxProfile] = []
  public private(set) var hosts: [SandboxHost] = []
  public private(set) var hasLoaded = false
  public var errorMessage: String?

  public init() {}

  public var accountProviders: [ServerSandboxProviderInfo] { providers.providers.filter(\.usesAccounts) }

  public func load(from client: any CodevisorServerClienting, machines: [SandboxMachine]) async {
    providers = (try? await client.sandboxProviders()) ?? providers
    accounts = (try? await client.sandboxAccounts()) ?? accounts
    profiles = (try? await client.sandboxProfiles()) ?? profiles
    hosts = await Self.hosts(on: machines)
    hasLoaded = true
  }

  public func provider(_ id: String) -> ServerSandboxProviderInfo? { providers.provider(id) }

  public func accounts(for providerId: String) -> [ServerSandboxAccount] {
    accounts.filter { $0.provider == providerId }
  }

  public func hosts(for capability: String?) -> [SandboxHost] {
    guard let capability else { return hosts }
    return hosts.filter { $0.capabilities.contains(capability) }
  }

  public func title(of account: ServerSandboxAccount) -> String {
    account.title(providerName: provider(account.provider)?.displayName ?? account.provider)
  }

  public func summary(of profile: ServerSandboxProfile) -> String {
    let provider = provider(profile.provider)
    let account = profile.accountId.flatMap { id in accounts.first { $0.id == id } }
    let place = profile.machineId(for: provider).map(hostName) ?? account.map(title(of:))
    let image = profile.values["image"]?.text ?? profile.values["template"]?.text
    return [place ?? provider?.displayName ?? profile.provider, image].compactMap(\.self).joined(separator: " · ")
  }

  public func save(_ draft: SandboxAccountDraft, using client: any CodevisorServerClienting) async -> Bool {
    await attempt {
      let saved =
        if let id = draft.accountId {
          try await client.updateSandboxAccount(id: id, draft.request)
        } else {
          try await client.createSandboxAccount(draft.request)
        }
      accounts = Self.replacing(saved, in: accounts)
    }
  }

  public func save(_ draft: SandboxProfileDraft, using client: any CodevisorServerClienting) async -> Bool {
    await attempt {
      let saved =
        if let id = draft.profileId {
          try await client.updateSandboxProfile(id: id, draft.request)
        } else {
          try await client.createSandboxProfile(draft.request)
        }
      profiles = Self.replacing(saved, in: profiles)
    }
  }

  public func delete(_ account: ServerSandboxAccount, using client: any CodevisorServerClienting) async {
    _ = await attempt {
      try await client.deleteSandboxAccount(id: account.id)
      accounts.removeAll { $0.id == account.id }
    }
  }

  public func delete(_ profile: ServerSandboxProfile, using client: any CodevisorServerClienting) async {
    _ = await attempt {
      try await client.deleteSandboxProfile(id: profile.id)
      profiles.removeAll { $0.id == profile.id }
    }
  }

  private func hostName(_ serverId: String) -> String {
    hosts.first { $0.serverId == serverId }?.name ?? "Another Mac"
  }

  private func attempt(_ work: () async throws -> Void) async -> Bool {
    do {
      try await work()
      errorMessage = nil
      return true
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
      return false
    }
  }

  private static func replacing<Item: Identifiable>(_ item: Item, in items: [Item]) -> [Item] {
    guard let index = items.firstIndex(where: { $0.id == item.id }) else { return items + [item] }
    var updated = items
    updated[index] = item
    return updated
  }

  private static func hosts(on machines: [SandboxMachine]) async -> [SandboxHost] {
    var hosts: [SandboxHost] = []
    for machine in machines {
      guard let host = await host(machine) else { continue }
      hosts.append(host)
    }
    return hosts
  }

  private static func host(_ machine: SandboxMachine) async -> SandboxHost? {
    guard let info = try? await machine.client.info(),
      let capabilities = try? await machine.client.sandboxProviders().capabilities,
      !capabilities.isEmpty
    else { return nil }
    return SandboxHost(serverId: info.id, name: machine.name, capabilities: Set(capabilities))
  }
}
