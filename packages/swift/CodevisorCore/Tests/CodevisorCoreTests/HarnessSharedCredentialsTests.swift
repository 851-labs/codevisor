import ACPKit
import Foundation
import Testing

@testable import CodevisorCore

@Suite("HarnessSharedCredentials")
struct HarnessSharedCredentialsTests {
  @Test("OpenCode lists shared credentials without exposing secrets or OAuth")
  func sharedMetadata() throws {
    let entries = try HarnessSharedCredentials.opencode.credentials(
      from:
        #"{"openai":{"type":"api","key":"private"},"anthropic":{"type":"oauth","access":"local"},"cloudflare":{"type":"wellknown","token":"private"}}"#
    )
    #expect(entries.map(\.id) == ["cloudflare", "openai"])
    #expect(entries.map(\.canReplaceKey) == [false, true])
    #expect(
      try HarnessSharedCredentials.pi.credentials(
        from: #"{"openai":{"type":"api_key","key":"private"},"anthropic":{"type":"oauth"}}"#
      ).map(\.id) == ["openai"])
    #expect(HarnessSharedCredentials(rawValue: "claude-code") == nil)
  }

  @Test("Replacing one provider preserves other credentials and provider metadata")
  func replace() throws {
    let content = #"{"openai":{"type":"api","key":"old","organization":"org"},"anthropic":{"type":"api","key":"keep"}}"#
    let edited = try HarnessSharedCredentials.opencode.replacingKey(in: content, providerId: "openai", key: " new ")
    let object = try JSONDecoder().decode(JSONValue.self, from: Data(edited.utf8))
    #expect(
      object
        == .object([
          "openai": .object(["type": .string("api"), "key": .string("new"), "organization": .string("org")]),
          "anthropic": .object(["type": .string("api"), "key": .string("keep")]),
        ]))
    #expect(
      try HarnessSharedCredentials.pi.replacingKey(in: nil, providerId: "openai", key: "new")
        == #"{"openai":{"key":"new","type":"api_key"}}"#)
  }

  @Test("Removing the last provider publishes an empty map, whole-file credentials use deletion")
  func remove() throws {
    #expect(
      try HarnessSharedCredentials.opencode.removing(
        from: #"{"openai":{"type":"api","key":"old"}}"#, providerId: "openai") == "{}")
    #expect(try HarnessSharedCredentials.codex.removing(from: nil, providerId: "openai") == nil)
    #expect(try HarnessSharedCredentials.devin.removing(from: "credentials", providerId: "devin") == nil)
  }

  @Test("Edits reject invalid documents and local sign-ins without replacing them")
  func rejectUnsafeEdits() {
    #expect(throws: (any Error).self) {
      try HarnessSharedCredentials.opencode.replacingKey(in: "broken", providerId: "openai", key: "new")
    }
    #expect(throws: (any Error).self) {
      try HarnessSharedCredentials.opencode.replacingKey(
        in: #"{"openai":{"type":"oauth"}}"#, providerId: "openai", key: "new")
    }
    #expect(throws: (any Error).self) {
      try HarnessSharedCredentials.codex.replacingKey(
        in: #"{"tokens":{"access_token":"local"}}"#, providerId: "openai", key: "new")
    }
    #expect(throws: (any Error).self) {
      try HarnessSharedCredentials.pi.replacingKey(in: nil, providerId: "openai", key: " ")
    }
  }
}
