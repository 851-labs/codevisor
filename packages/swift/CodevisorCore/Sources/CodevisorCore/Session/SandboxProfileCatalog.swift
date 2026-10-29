import CodevisorClient
import Foundation
import Observation

public enum SandboxProfileAvailability: Equatable, Sendable {
  case checking
  case available
  case unavailable(String)
}

public struct SandboxProfileChoice: Equatable, Identifiable, Sendable {
  public let target: SandboxTarget
  public let availability: SandboxProfileAvailability

  public var id: String { target.id }

  public init(target: SandboxTarget, availability: SandboxProfileAvailability) {
    self.target = target
    self.availability = availability
  }
}

public enum SandboxHostConnection: Sendable {
  case ready(any CodevisorServerClienting)
  case starting
  case unreachable
}

public struct SandboxProfilesLoadKey: Equatable, Sendable {
  let composerId: String
  let machineAvailabilities: [String: ServerAvailability]
  let machineServerIds: [String: String?]
  let revision: Int
}

@MainActor
@Observable
public final class SandboxProfileCatalog {
  static let disconnectedHostReason = "Its Mac isn't connected"

  private var targets: [SandboxTarget] = []
  private var reasonsByComposer: [String: [String: String?]] = [:]
  private var checkingByComposer: [String: Set<String>] = [:]

  public init() {}

  public func choices(for composerId: String) -> [SandboxProfileChoice] {
    targets.map { SandboxProfileChoice(target: $0, availability: availability(of: $0.profileId, for: composerId)) }
  }

  public func availability(of profileId: String, for composerId: String) -> SandboxProfileAvailability {
    if checkingByComposer[composerId]?.contains(profileId) == true { return .checking }
    guard let known = reasonsByComposer[composerId]?[profileId] else { return .checking }
    guard let reason = known else { return .available }
    return .unavailable(reason)
  }

  public func load(
    composerId: String,
    from composer: any CodevisorServerClienting,
    host: (String) -> SandboxHostConnection
  ) async {
    guard let loaded = await Self.targets(from: composer) else { return }
    targets = loaded

    let checks = Self.availabilityChecks(for: loaded, composer: composer, host: host)
    checkingByComposer[composerId] = Set(checks.sources.flatMap(\.profileIds) + checks.startingProfileIds)
    for profileId in checks.disconnectedProfileIds {
      setReason(Self.disconnectedHostReason, for: profileId, composerId: composerId)
    }
    await withTaskGroup(of: ([String], [String: String?]?).self) { group in
      for check in checks.sources {
        group.addTask { (check.profileIds, await Self.availability(from: check.client)) }
      }
      for await (profileIds, answer) in group {
        record(answer, for: profileIds, composerId: composerId)
      }
    }
  }

  private func record(_ answer: [String: String?]?, for profileIds: [String], composerId: String) {
    for profileId in profileIds {
      checkingByComposer[composerId]?.remove(profileId)
      if let answer {
        setReason(answer[profileId] ?? nil, for: profileId, composerId: composerId)
      } else if reasonsByComposer[composerId]?[profileId] == nil {
        setReason(nil, for: profileId, composerId: composerId)
      }
    }
  }

  private func setReason(_ reason: String?, for profileId: String, composerId: String) {
    reasonsByComposer[composerId, default: [:]][profileId] = .some(reason)
  }

  private static func targets(from composer: any CodevisorServerClienting) async -> [SandboxTarget]? {
    async let vendors = composer.sandboxVendors()
    async let providers = composer.sandboxProviders()
    async let profiles = composer.sandboxProfiles()
    guard let vendors = try? await vendors, let providers = try? await providers, let profiles = try? await profiles
    else { return nil }
    return profiles.map { profile in
      SandboxTarget(
        profile: profile, vendor: vendors.vendor(profile.vendor),
        provider: providers.first { $0.id == profile.providerId })
    }
  }

  private struct AvailabilityChecks {
    var sources: [AvailabilitySource] = []
    var startingProfileIds: [String] = []
    var disconnectedProfileIds: [String] = []
  }

  private struct AvailabilitySource: Sendable {
    let client: any CodevisorServerClienting
    let profileIds: [String]
  }

  private static func availabilityChecks(
    for targets: [SandboxTarget],
    composer: any CodevisorServerClienting,
    host: (String) -> SandboxHostConnection
  ) -> AvailabilityChecks {
    var profileIdsByHost: [String?: [String]] = [:]
    for target in targets {
      profileIdsByHost[target.hostMachineId, default: []].append(target.profileId)
    }

    var checks = AvailabilityChecks()
    for (hostId, profileIds) in profileIdsByHost {
      switch availabilityHost(forHost: hostId, composer: composer, host: host) {
      case let .ready(client): checks.sources.append(AvailabilitySource(client: client, profileIds: profileIds))
      case .starting: checks.startingProfileIds += profileIds
      case .unreachable: checks.disconnectedProfileIds += profileIds
      }
    }
    return checks
  }

  private static func availabilityHost(
    forHost hostId: String?,
    composer: any CodevisorServerClienting,
    host: (String) -> SandboxHostConnection
  ) -> SandboxHostConnection {
    guard let hostId else { return .ready(composer) }
    return host(hostId)
  }

  private nonisolated static func availability(from client: any CodevisorServerClienting) async -> [String: String?]? {
    guard let entries = try? await client.sandboxAvailability() else { return nil }
    return Dictionary(entries.map { ($0.profileId, $0.disabledReason) }, uniquingKeysWith: { first, _ in first })
  }
}
