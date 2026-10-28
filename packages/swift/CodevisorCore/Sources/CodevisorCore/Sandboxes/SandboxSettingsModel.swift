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
    async let vendors = try? client.sandboxVendors()
    async let providers = try? client.sandboxProviders()
    async let profiles = try? client.sandboxProfiles()
    self.vendors = await vendors ?? self.vendors
    self.providers = await providers ?? self.providers
    self.profiles = await profiles ?? self.profiles
    guard !Task.isCancelled else { return }
    hasLoaded = true
    await loadHosts(on: machines)
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

  private func loadHosts(on machines: [SandboxMachine]) async {
    var found: [Int: SandboxHost] = [:]
    await withTaskGroup(of: (Int, SandboxHost?).self) { group in
      for (index, machine) in machines.enumerated() {
        group.addTask { (index, await Self.host(machine)) }
      }
      for await (index, host) in group {
        guard let host else { continue }
        found[index] = host
        hosts = hosts.filter { $0.serverId != host.serverId } + [host]
      }
    }
    guard !Task.isCancelled else { return }
    hosts = found.sorted { $0.key < $1.key }.map(\.value)
  }

  private static func host(_ machine: SandboxMachine) async -> SandboxHost? {
    async let info = try? machine.client.info()
    async let vendors = try? machine.client.sandboxVendors()
    guard let info = await info, let vendors = await vendors, !vendors.capabilities.isEmpty else { return nil }
    return SandboxHost(
      serverId: info.id, name: machine.name, capabilities: Set(vendors.capabilities), maximums: vendors.maximums)
  }
}
