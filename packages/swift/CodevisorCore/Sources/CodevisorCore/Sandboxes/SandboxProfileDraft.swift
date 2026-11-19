import CodevisorClient
import Foundation

public struct SandboxProfileDraft: Equatable, Identifiable, Sendable {
  public var profileId: String?
  public let vendor: ServerSandboxVendor?
  public let providerId: String?
  public var name: String
  public var fields: SandboxFieldDraft

  public static let nameKey = "name"

  public var id: String { profileId ?? "new" }

  public var fieldKeys: [String] {
    [Self.nameKey] + (vendor?.profileFields ?? []).map(\.key)
  }
  public var isNew: Bool { profileId == nil }

  public var canSave: Bool {
    guard let vendor, providerId != nil else { return false }
    return !trimmedName.isEmpty && fields.isFilled(vendor.profileFields)
  }

  public init(provider: ServerSandboxProvider, vendor: ServerSandboxVendor) {
    self.vendor = vendor
    providerId = provider.id
    name = Self.defaultName(vendor)
    fields = SandboxFieldDraft(fields: vendor.profileFields, values: [:])
  }

  public init(profile: ServerSandboxProfile, vendor: ServerSandboxVendor?) {
    profileId = profile.id
    self.vendor = vendor
    providerId = profile.providerId
    name = profile.name
    fields = SandboxFieldDraft(fields: vendor?.profileFields ?? [], values: profile.values)
  }

  public var request: ServerSandboxProfileRequest? {
    guard let vendor else { return nil }
    return ServerSandboxProfileRequest(
      name: trimmedName, vendor: vendor.id, providerId: providerId, values: fields.values(for: vendor.profileFields))
  }

  private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  private static func defaultName(_ vendor: ServerSandboxVendor) -> String {
    vendor.sandboxNoun.prefix(1).uppercased() + vendor.sandboxNoun.dropFirst()
  }
}
