import ACPKit
import Foundation

/// The same static credential surfaces handled by the server's credential ferry.
/// Account profiles and OAuth sessions are deliberately outside this model.
public enum HarnessSharedCredentials: String, Sendable {
  case opencode, pi, codex, devin

  public static let namespace = "harness-credentials"

  public struct Credential: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let kind: String
    public let canReplaceKey: Bool
  }

  public var sourceKey: String {
    switch self {
    case .opencode: "opencode-auth"
    case .pi: "pi-auth"
    case .codex: "codex-auth-file"
    case .devin: "devin-credentials-file"
    }
  }

  public var hasProviders: Bool { self == .opencode || self == .pi }

  @MainActor
  public func content(in sync: ConfigSync) -> String? {
    _ = sync.revisionsByNamespace[Self.namespace]
    guard case .string(let content) = sync.value(namespace: Self.namespace, key: sourceKey) else { return nil }
    return content
  }

  public func credentials(from content: String?) throws -> [Credential] {
    guard let content, !content.isEmpty else { return [] }
    if self == .devin {
      return [.init(id: "devin", name: "Devin", kind: "Credential file", canReplaceKey: false)]
    }
    let fields = try document(content)
    if self == .codex {
      guard case .string(let key) = fields["OPENAI_API_KEY"], !key.isEmpty else { return [] }
      return [.init(id: "openai", name: "OpenAI", kind: "API key", canReplaceKey: true)]
    }
    return fields.compactMap { id, value in
      guard case .object(let credential) = value, case .string(let type) = credential["type"],
        self == .pi ? type == "api_key" : type != "oauth"
      else { return nil }
      let isKey = type == "api" || type == "api_key"
      return Credential(
        id: id, name: Self.providerName(id), kind: isKey ? "API key" : "External credential", canReplaceKey: isKey)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Merge into the latest document at Save time, preserving other providers
  /// and metadata instead of writing a stale snapshot from the editor.
  public func replacingKey(in content: String?, providerId: String, key: String) throws -> String {
    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
    let id = providerId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard self != .devin, !key.isEmpty, !id.isEmpty else { throw CredentialError.invalidInput }
    var fields = try document(content)
    if self == .codex {
      fields["OPENAI_API_KEY"] = .string(key)
    } else {
      var credential: [String: JSONValue] = [:]
      if case .object(let existing) = fields[id] {
        guard existing["type"] == .string(self == .pi ? "api_key" : "api") else {
          throw CredentialError.unsupportedCredential
        }
        credential = existing
      }
      credential["type"] = .string(self == .pi ? "api_key" : "api")
      credential["key"] = .string(key)
      fields[id] = .object(credential)
    }
    return try encode(fields)
  }

  /// Empty provider maps must remain live documents so removals reach peers.
  /// Whole-file sources use the ferry's explicit deletion path.
  public func removing(from content: String?, providerId: String) throws -> String? {
    guard hasProviders else { return nil }
    var fields = try document(content)
    fields.removeValue(forKey: providerId)
    return try encode(fields)
  }

  public static func providerName(_ id: String) -> String {
    let names = [
      "anthropic": "Anthropic", "openai": "OpenAI", "google": "Google", "opencode": "OpenCode Zen",
      "openrouter": "OpenRouter", "github-copilot": "GitHub Copilot", "groq": "Groq",
      "xai": "xAI", "mistral": "Mistral", "deepseek": "DeepSeek", "amazon-bedrock": "Amazon Bedrock",
      "azure": "Azure", "cerebras": "Cerebras", "cloudflare": "Cloudflare",
    ]
    return names[id] ?? id
  }

  private func document(_ content: String?) throws -> [String: JSONValue] {
    guard let content else { return [:] }
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(content.utf8)),
      case .object(let fields) = value
    else { throw CredentialError.invalidDocument }
    if self == .codex, case .object = fields["tokens"] {
      throw CredentialError.unsupportedCredential
    }
    return fields
  }

  private func encode(_ fields: [String: JSONValue]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(JSONValue.object(fields)), as: UTF8.self)
  }

  public enum CredentialError: LocalizedError {
    case invalidInput, invalidDocument, unsupportedCredential

    public var errorDescription: String? {
      switch self {
      case .invalidInput: "Enter a provider and API key."
      case .invalidDocument: "Shared credentials couldn’t be read."
      case .unsupportedCredential: "Manage this sign-in on its machine."
      }
    }
  }
}
