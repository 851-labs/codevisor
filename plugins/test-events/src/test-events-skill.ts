import type { SkillDefinition } from "@codevisor/plugin-kit"

export const testEventsSkill: SkillDefinition = {
  name: "test-events",
  description: "Exercise Codevisor plugin events end to end with the test-events plugin.",
  instructions: [
    "# Test events",
    "",
    "Use this plugin to check that event subscriptions wake an agent.",
    "",
    "1. Subscribe to `test.ping` or `test.counter`.",
    '2. Call the `emit` tool with `{ "name": "test.ping", "data": { "level": "warn" } }`.',
    "3. Confirm the event arrives, then call `list_recent` to compare.",
    "",
    "Payload fields are listed in `references/payloads.md`.",
    ""
  ].join("\n"),
  files: [
    {
      path: "references/payloads.md",
      mimeType: "text/markdown",
      text: [
        "# Payloads",
        "",
        "- `test.ping`: `message` (string), `level` (`info`, `warn` or `error`), `tags` (strings), `count` (integer).",
        "- `test.counter`: `value` (integer).",
        ""
      ].join("\n")
    }
  ]
}
