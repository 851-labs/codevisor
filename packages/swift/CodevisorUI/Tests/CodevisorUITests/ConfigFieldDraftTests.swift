import CodevisorCore
import Testing

@testable import CodevisorUI

struct ConfigFieldDraftTests {
  @Test("A saved secret satisfies its required field and is only sent when replaced")
  func savedSecret() {
    let fields = [
      ServerConfigField(key: "url", label: "URL", type: .url, required: true),
      ServerConfigField(key: "token", label: "Token", type: .secret, required: true),
    ]
    var draft = ConfigFieldDraft(fields: fields, values: ["url": .string("https://g.example")], secretsSet: ["token"])

    #expect(draft.isComplete)
    #expect(draft.keepsSavedSecret(fields[1]))
    #expect(draft.submittedValues == ["url": .string("https://g.example")])

    draft.values["url"] = .string("  ")
    #expect(!draft.isComplete)
  }

  @Test("A field hidden by its condition neither blocks completion nor submits a value")
  func conditionalField() {
    let fields = [
      ServerConfigField(key: "mode", label: "Mode", type: .choice, required: true, default: .string("oauth")),
      ServerConfigField(
        key: "apiKey", label: "API key", type: .secret, required: true,
        when: .init(key: "mode", op: "eq", value: .string("key"))),
    ]
    var draft = ConfigFieldDraft(fields: fields, values: ["apiKey": .string("stale")])

    #expect(draft.visibleFields.map(\.key) == ["mode"])
    #expect(draft.isComplete)
    #expect(draft.submittedValues == ["mode": .string("oauth")])

    draft.values["mode"] = .string("key")
    #expect(draft.visibleFields.map(\.key) == ["mode", "apiKey"])
  }

  @Test("A new account pre-fills each generated secret so it can be copied; a saved one stays hidden")
  func generatedSecret() {
    var field = ServerConfigField(key: "webhookSecret", label: "Webhook secret", type: .secret, required: true)
    field.generated = true

    let fresh = ConfigFieldDraft(fields: [field], generate: { "fixed-secret" })
    let saved = ConfigFieldDraft(fields: [field], secretsSet: ["webhookSecret"], generate: { "unused" })

    #expect(fresh.showsGeneratedValue(field))
    #expect(fresh.submittedValues == ["webhookSecret": .string("fixed-secret")])
    #expect(!saved.showsGeneratedValue(field))
    #expect(saved.submittedValues.isEmpty)
    #expect(saved.isComplete)
  }
}
