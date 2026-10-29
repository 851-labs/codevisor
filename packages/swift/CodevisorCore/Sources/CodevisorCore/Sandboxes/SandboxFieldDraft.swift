import CodevisorClient
import Foundation

public struct SandboxFieldDraft: Equatable, Sendable {
  public var text: [String: String] = [:]
  public var flags: [String: Bool] = [:]

  public init() {}

  public init(fields: [ServerSandboxField], values: [String: SandboxFieldValue]) {
    for field in fields {
      let value = values[field.key] ?? field.defaultValue
      if field.type == .boolean {
        flags[field.key] = value == .bool(true)
      } else if field.type != .secret {
        text[field.key] = value?.text ?? ""
      }
    }
  }

  public func carried(from oldFields: [ServerSandboxField], to newFields: [ServerSandboxField]) -> SandboxFieldDraft {
    let untouched = SandboxFieldDraft(fields: oldFields, values: [:])
    var carried = SandboxFieldDraft(fields: newFields, values: [:])
    for field in newFields {
      guard let old = oldFields.first(where: { $0.key == field.key }), old.type == field.type else { continue }
      if field.type == .boolean, flags[field.key] != untouched.flags[field.key] {
        carried.flags[field.key] = flags[field.key]
      } else if let typed = text[field.key], typed != untouched.text[field.key], Self.fits(typed, field) {
        carried.text[field.key] = typed
      }
    }
    return carried
  }

  public func values(for fields: [ServerSandboxField]) -> [String: SandboxFieldValue] {
    var values: [String: SandboxFieldValue] = [:]
    for field in fields {
      values[field.key] = value(for: field)
    }
    return values
  }

  public func isFilled(_ fields: [ServerSandboxField], secretsSet: Set<String> = []) -> Bool {
    fields.filter(\.required).allSatisfy { field in
      value(for: field) != nil || secretsSet.contains(field.key)
    }
  }

  private static func fits(_ text: String, _ field: ServerSandboxField) -> Bool {
    guard field.type == .choice else { return true }
    return field.choices?.contains { $0.value == text } ?? false
  }

  private func value(for field: ServerSandboxField) -> SandboxFieldValue? {
    if field.type == .boolean { return flags[field.key].map(SandboxFieldValue.bool) }
    let raw = (text[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return nil }
    if field.type == .number, let number = Double(raw) { return .number(number) }
    return .string(raw)
  }
}
