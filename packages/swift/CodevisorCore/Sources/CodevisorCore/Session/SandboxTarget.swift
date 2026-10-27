import CodevisorClient
import Foundation

public struct SandboxTarget: Equatable, Hashable, Sendable, Identifiable {
  public let profileId: String
  public let profileName: String
  public let providerId: String
  public let machineNoun: String
  public let hostMachineId: String?

  public var id: String { profileId }
  public var pickerTitle: String { "New \(profileName)" }

  public var systemImage: String {
    switch providerId {
    case "tart", "tart-orchard": "desktopcomputer"
    default: "shippingbox"
    }
  }

  public init(
    profileId: String,
    profileName: String,
    providerId: String,
    machineNoun: String,
    hostMachineId: String? = nil
  ) {
    self.profileId = profileId
    self.profileName = profileName
    self.providerId = providerId
    self.machineNoun = machineNoun
    self.hostMachineId = hostMachineId
  }

  public init(profile: ServerSandboxProfile, provider: ServerSandboxProviderInfo?) {
    self.init(
      profileId: profile.id,
      profileName: profile.name,
      providerId: profile.provider,
      machineNoun: provider?.sandboxNoun ?? "sandbox",
      hostMachineId: profile.machineId(for: provider)
    )
  }
}
