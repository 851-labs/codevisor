import CodevisorClient
import Foundation

public struct SandboxTarget: Equatable, Hashable, Sendable, Identifiable {
  public let profileId: String
  public let profileName: String
  public let vendorId: String
  public let machineNoun: String
  public let hostMachineId: String?

  public var id: String { profileId }
  public var pickerTitle: String { "New \(profileName)" }
  public var systemImage: String { SandboxVendorSymbol.name(for: vendorId) }

  public init(
    profileId: String,
    profileName: String,
    vendorId: String,
    machineNoun: String,
    hostMachineId: String? = nil
  ) {
    self.profileId = profileId
    self.profileName = profileName
    self.vendorId = vendorId
    self.machineNoun = machineNoun
    self.hostMachineId = hostMachineId
  }

  public init(profile: ServerSandboxProfile, vendor: ServerSandboxVendor?, provider: ServerSandboxProvider?) {
    self.init(
      profileId: profile.id,
      profileName: profile.name,
      vendorId: profile.vendor,
      machineNoun: vendor?.sandboxNoun ?? "sandbox",
      hostMachineId: profile.machineId(vendor: vendor, provider: provider)
    )
  }
}
