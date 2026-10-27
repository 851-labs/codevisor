import CodevisorClient
import Foundation

public struct SandboxProviderDraft: Equatable, Identifiable, Sendable {
  public var providerId: String?
  public private(set) var vendor: ServerSandboxVendor?
  public var label: String
  public var fields: SandboxFieldDraft
  public var secretsSet: Set<String>

  public var id: String { providerId ?? "new" }
  public var isNew: Bool { providerId == nil }

  public var canSave: Bool {
    guard let vendor else { return false }
    return fields.isFilled(vendor.providerFields, secretsSet: secretsSet)
  }

  public init(vendor: ServerSandboxVendor? = nil, provider: ServerSandboxProvider? = nil) {
    providerId = provider?.id
    self.vendor = vendor
    label = provider?.label ?? ""
    fields = SandboxFieldDraft(fields: vendor?.providerFields ?? [], values: provider?.values ?? [:])
    secretsSet = Set(provider?.secretsSet ?? [])
  }

  public mutating func choose(_ vendor: ServerSandboxVendor) {
    guard vendor.id != self.vendor?.id else { return }
    self = SandboxProviderDraft(vendor: vendor)
  }

  public var request: ServerSandboxProviderRequest? {
    guard let vendor else { return nil }
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    return ServerSandboxProviderRequest(
      vendor: vendor.id, label: trimmed.isEmpty ? nil : trimmed, values: fields.values(for: vendor.providerFields))
  }
}
