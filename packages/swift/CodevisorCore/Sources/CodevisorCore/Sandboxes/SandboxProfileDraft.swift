import CodevisorClient
import Foundation

public struct SandboxProfileDraft: Equatable, Identifiable, Sendable {
  public var profileId: String?
  public private(set) var vendor: ServerSandboxVendor?
  public private(set) var providerId: String?
  public var name: String
  public var fields: SandboxFieldDraft

  public var id: String { profileId ?? "new" }
  public var isNew: Bool { profileId == nil }

  public var canSave: Bool {
    guard let vendor, providerId != nil else { return false }
    return !trimmedName.isEmpty && fields.isFilled(vendor.profileFields)
  }

  public init(provider: ServerSandboxProvider, vendor: ServerSandboxVendor) {
    name = ""
    fields = SandboxFieldDraft()
    choose(provider, vendor: vendor)
  }

  public init(profile: ServerSandboxProfile, vendor: ServerSandboxVendor?) {
    profileId = profile.id
    self.vendor = vendor
    providerId = profile.providerId
    name = profile.name
    fields = SandboxFieldDraft(fields: vendor?.profileFields ?? [], values: profile.values)
  }

  public mutating func choose(_ provider: ServerSandboxProvider, vendor: ServerSandboxVendor) {
    providerId = provider.id
    adopt(vendor)
  }

  public var request: ServerSandboxProfileRequest? {
    guard let vendor else { return nil }
    return ServerSandboxProfileRequest(
      name: trimmedName, vendor: vendor.id, providerId: providerId, values: fields.values(for: vendor.profileFields))
  }

  private mutating func adopt(_ vendor: ServerSandboxVendor) {
    guard vendor.id != self.vendor?.id else { return }

    if name.isEmpty || name == self.vendor.map(Self.defaultName) { name = Self.defaultName(vendor) }
    fields = fields.carried(from: self.vendor?.profileFields ?? [], to: vendor.profileFields)
    self.vendor = vendor
  }

  private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  private static func defaultName(_ vendor: ServerSandboxVendor) -> String {
    vendor.sandboxNoun.prefix(1).uppercased() + vendor.sandboxNoun.dropFirst()
  }
}
