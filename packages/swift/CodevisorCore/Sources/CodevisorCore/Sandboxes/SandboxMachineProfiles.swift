import CodevisorClient
import Foundation
import Observation

public struct SandboxMachineProfile: Equatable, Sendable {
  public let id: String
  public let name: String
  public let vendor: String

  public init(id: String, name: String, vendor: String) {
    self.id = id
    self.name = name
    self.vendor = vendor
  }
}

public struct SandboxOwner: Sendable {
  let deviceId: String
  let client: any CodevisorServerClienting
}

public struct SandboxMachineProfilesLoadKey: Equatable, Sendable {
  let sandboxDeviceIds: Set<String>
  let ownerAvailabilities: [String: ServerAvailability?]
  let revision: Int
}

@MainActor
@Observable
public final class SandboxMachineProfiles {
  public static let recordsNamespace = "sandbox-records"

  private var profilesByOwner: [String: [String: SandboxMachineProfile]] = [:]
  private var powersByOwner: [String: [String: SandboxMachinePower]] = [:]
  private var sandboxIdsByOwner: [String: [String: String]] = [:]

  public init() {}

  public func profile(forDevice deviceId: String, ownedBy ownerDeviceId: String) -> SandboxMachineProfile? {
    profilesByOwner[ownerDeviceId]?[deviceId]
  }

  public func power(forDevice deviceId: String, ownedBy ownerDeviceId: String) -> SandboxMachinePower? {
    powersByOwner[ownerDeviceId]?[deviceId]
  }

  func sandboxId(forDevice deviceId: String, ownedBy ownerDeviceId: String) -> String? {
    sandboxIdsByOwner[ownerDeviceId]?[deviceId]
  }

  func markWaking(device deviceId: String, ownedBy ownerDeviceId: String) {
    guard let paused = power(forDevice: deviceId, ownedBy: ownerDeviceId) else { return }
    powersByOwner[ownerDeviceId]?[deviceId] = SandboxMachinePower(sandboxId: paused.sandboxId, power: .waking)
  }

  func load(from owners: [SandboxOwner]) async {
    await withTaskGroup(of: (String, OwnerSandboxes?).self) { group in
      for owner in owners {
        group.addTask { (owner.deviceId, await Self.sandboxes(on: owner.client)) }
      }
      for await (ownerDeviceId, loaded) in group {
        guard let loaded else { continue }
        store(loaded, for: ownerDeviceId)
      }
    }
  }

  private func store(_ loaded: OwnerSandboxes, for ownerDeviceId: String) {
    if profilesByOwner[ownerDeviceId] != loaded.profiles { profilesByOwner[ownerDeviceId] = loaded.profiles }
    if powersByOwner[ownerDeviceId] != loaded.powers { powersByOwner[ownerDeviceId] = loaded.powers }
    if sandboxIdsByOwner[ownerDeviceId] != loaded.sandboxIds { sandboxIdsByOwner[ownerDeviceId] = loaded.sandboxIds }
  }

  private nonisolated static func sandboxes(on client: any CodevisorServerClienting) async -> OwnerSandboxes? {
    async let sandboxes = try? client.sandboxes()
    async let profiles = try? client.sandboxProfiles()
    guard let sandboxes = await sandboxes, let profiles = await profiles else { return nil }
    return OwnerSandboxes(
      profiles: matching(sandboxes, to: profiles), powers: SandboxMachinePower.byDevice(sandboxes),
      sandboxIds: sandboxIdsByDevice(sandboxes))
  }

  private nonisolated static func sandboxIdsByDevice(_ sandboxes: [ServerSandbox]) -> [String: String] {
    var ids: [String: String] = [:]
    for sandbox in sandboxes {
      guard let deviceId = sandbox.deviceId else { continue }
      ids[deviceId] = sandbox.id
    }
    return ids
  }

  private nonisolated static func matching(
    _ sandboxes: [ServerSandbox], to profiles: [ServerSandboxProfile]
  ) -> [String: SandboxMachineProfile] {
    let profilesById = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var matched: [String: SandboxMachineProfile] = [:]
    for sandbox in sandboxes {
      guard let deviceId = sandbox.deviceId, let profile = sandbox.profileId.flatMap({ profilesById[$0] }) else {
        continue
      }
      matched[deviceId] = SandboxMachineProfile(id: profile.id, name: profile.name, vendor: profile.vendor)
    }
    return matched
  }
}

private struct OwnerSandboxes: Sendable {
  let profiles: [String: SandboxMachineProfile]
  let powers: [String: SandboxMachinePower]
  let sandboxIds: [String: String]
}
