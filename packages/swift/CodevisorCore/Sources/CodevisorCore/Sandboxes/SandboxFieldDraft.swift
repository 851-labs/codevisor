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

  private func value(for field: ServerSandboxField) -> SandboxFieldValue? {
    if field.type == .boolean { return flags[field.key].map(SandboxFieldValue.bool) }
    let raw = (text[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return nil }
    if field.type == .number, let number = Double(raw) { return .number(number) }
    return .string(raw)
  }
}
