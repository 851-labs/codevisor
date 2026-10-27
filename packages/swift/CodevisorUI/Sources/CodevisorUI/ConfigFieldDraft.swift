import CodevisorCore
import Foundation

public struct ConfigFieldDraft: Equatable, Sendable {
  public let fields: [ServerConfigField]
  public let secretsSet: Set<String>
  public var values: [String: ServerConfigFieldValue]

  public init(
    fields: [ServerConfigField],
    values existing: [String: ServerConfigFieldValue] = [:],
    secretsSet: [String] = [],
    generate: () -> String = ConfigFieldDraft.randomSecret
  ) {
    self.fields = fields
    self.secretsSet = Set(secretsSet)
    values = Self.defaults(for: fields).merging(existing) { _, saved in saved }
    for field in fields where showsGeneratedValue(field) && values[field.key] == nil {
      values[field.key] = .string(generate())
    }
  }

  public static func randomSecret() -> String {
    let bytes = (0..<secretByteCount).map { _ in UInt8.random(in: .min ... .max) }
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  public var visibleFields: [ServerConfigField] {
    fields.filter { $0.isVisible(with: values) }
  }

  public var isComplete: Bool {
    visibleFields.allSatisfy(isFilled)
  }

  public var submittedValues: [String: ServerConfigFieldValue] {
    let keys = Set(visibleFields.map(\.key))
    return values.filter { keys.contains($0.key) && !Self.isBlank($0.value) }
  }

  public func keepsSavedSecret(_ field: ServerConfigField) -> Bool {
    field.isSecret && secretsSet.contains(field.key)
  }

  public func showsGeneratedValue(_ field: ServerConfigField) -> Bool {
    field.isGenerated && !secretsSet.contains(field.key)
  }

  private static let secretByteCount = 24

  private func isFilled(_ field: ServerConfigField) -> Bool {
    guard field.required else { return true }
    if keepsSavedSecret(field) { return true }
    guard let value = values[field.key] else { return false }
    return !Self.isBlank(value)
  }

  private static func isBlank(_ value: ServerConfigFieldValue) -> Bool {
    guard case let .string(text) = value else { return false }
    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private static func defaults(for fields: [ServerConfigField]) -> [String: ServerConfigFieldValue] {
    var values: [String: ServerConfigFieldValue] = [:]
    for field in fields {
      values[field.key] = field.default
    }
    return values
  }
}
