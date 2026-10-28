import CodevisorClient
import Foundation
import Observation

public enum SandboxProviderSave: Equatable, Sendable {
  case saved(ServerSandboxProvider)
  case choose(ServerSandboxField)
  case failed
}

@MainActor
@Observable
public final class SandboxSettingsModel {
  public static let syncNamespaces = ["sandbox-accounts", "sandbox-profiles"]

  public private(set) var vendors = ServerSandboxVendors()
  public private(set) var providers: [ServerSandboxProvider] = []
  public private(set) var profiles: [ServerSandboxProfile] = []
  public private(set) var hosts: [SandboxHost] = []
  public private(set) var hasLoaded = false
  public var errorMessage: String?

  public init() {}

  public func load(from client: any CodevisorServerClienting, machines: [SandboxMachine]) async {
    vendors = (try? await client.sandboxVendors()) ?? vendors
    providers = (try? await client.sandboxProviders()) ?? providers
    profiles = (try? await client.sandboxProfiles()) ?? profiles
    hosts = await Self.hosts(on: machines)
    hasLoaded = true
  }

  public func vendor(_ id: String) -> ServerSandboxVendor? { vendors.vendor(id) }

  public func profile(_ id: String) -> ServerSandboxProfile? {
    profiles.first { $0.id == id }
  }

  public func provider(_ id: String?) -> ServerSandboxProvider? {
    id.flatMap { id in providers.first { $0.id == id } }
  }

  public func hosts(for capability: String?) -> [SandboxHost] {
    guard let capability else { return hosts }
    return hosts.filter { $0.capabilities.contains(capability) }
  }

  public func steps(for field: ServerSandboxField, in draft: SandboxProfileDraft) -> SandboxFieldSteps? {
    guard field.steps != nil else { return nil }

    let saved = profile(draft.profileId ?? "")?.values[field.key]?.numberValue
    return SandboxFieldSteps(
      field: field, hostMaximum: hostMaximum(of: field, providerId: draft.providerId), keeping: saved)
  }

  public func title(of provider: ServerSandboxProvider) -> String {
    let vendor = vendor(provider.vendor)
    let vendorName = vendor?.displayName ?? provider.vendor
    guard let machineId = provider.machineId(for: vendor) else { return provider.title(vendorName: vendorName) }
    return "\(vendorName) · \(hostName(machineId))"
  }

  public func save(
    _ draft: SandboxProviderDraft, using client: any CodevisorServerClienting
  ) async
    -> SandboxProviderSave
  {
    guard let request = draft.request else { return .failed }

    do {
      let provider =
        if let id = draft.providerId {
          try await client.updateSandboxProvider(id: id, request)
        } else {
          try await client.createSandboxProvider(request)
        }
      providers = Self.replacing(provider, in: providers)
      errorMessage = nil
      return .saved(provider)
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
      return ServerSandboxField.offered(in: error).map(SandboxProviderSave.choose) ?? .failed
    }
  }

  public func save(_ draft: SandboxProfileDraft, using client: any CodevisorServerClienting) async -> Bool {
    guard let request = draft.request else { return false }

    return await attempt {
      let saved =
        if let id = draft.profileId {
          try await client.updateSandboxProfile(id: id, request)
        } else {
          try await client.createSandboxProfile(request)
        }
      profiles = Self.replacing(saved, in: profiles)
    }
  }

  public func delete(_ profile: ServerSandboxProfile, using client: any CodevisorServerClienting) async {
    let deleted = await attempt {
      try await client.deleteSandboxProfile(id: profile.id)
      profiles.removeAll { $0.id == profile.id }
    }
    guard deleted, let provider = provider(profile.providerId),
      !profiles.contains(where: { $0.providerId == provider.id })
    else { return }
    guard (try? await client.deleteSandboxProvider(id: provider.id)) != nil else { return }
    providers.removeAll { $0.id == provider.id }
  }

  private func hostName(_ serverId: String) -> String {
    hosts.first { $0.serverId == serverId }?.name ?? "another Mac"
  }

  private func hostMaximum(of field: ServerSandboxField, providerId: String?) -> Double? {
    guard let provider = provider(providerId),
      let machineId = provider.machineId(for: vendor(provider.vendor))
    else { return nil }
    return hosts.first { $0.serverId == machineId }?.maximums[provider.vendor]?[field.key]
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
      let vendors = try? await machine.client.sandboxVendors(),
      !vendors.capabilities.isEmpty
    else { return nil }
    return SandboxHost(
      serverId: info.id, name: machine.name, capabilities: Set(vendors.capabilities), maximums: vendors.maximums)
  }
}
