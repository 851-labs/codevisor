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
  private var profilesByOwner: [String: [String: SandboxMachineProfile]] = [:]

  public init() {}

  public func profile(forDevice deviceId: String, ownedBy ownerDeviceId: String) -> SandboxMachineProfile? {
    profilesByOwner[ownerDeviceId]?[deviceId]
  }

  func load(from owners: [SandboxOwner]) async {
    await withTaskGroup(of: (String, [String: SandboxMachineProfile]?).self) { group in
      for owner in owners {
        group.addTask { (owner.deviceId, await Self.profilesByDevice(on: owner.client)) }
      }
      for await (ownerDeviceId, profiles) in group {
        guard let profiles, profilesByOwner[ownerDeviceId] != profiles else { continue }
        profilesByOwner[ownerDeviceId] = profiles
      }
    }
  }

  private nonisolated static func profilesByDevice(
    on client: any CodevisorServerClienting
  ) async -> [String: SandboxMachineProfile]? {
    async let sandboxes = try? client.sandboxes()
    async let profiles = try? client.sandboxProfiles()
    guard let sandboxes = await sandboxes, let profiles = await profiles else { return nil }
    return matching(sandboxes, to: profiles)
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
