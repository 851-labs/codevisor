import type { ConversationItem } from "@herdman/api"
import { describe, expect, it } from "vitest"

import { foldConversation } from "./conversation"

let counter = 0
function item(
  role: ConversationItem["role"],
  text: string,
  overrides: Partial<ConversationItem> = {}
): ConversationItem {
  counter += 1
  return {
    id: `item-${counter}`,
    role,
    text,
    createdAt: "2026-01-01T00:00:00.000Z",
    isGenerating: false,
    messageId: undefined,
    ...overrides
  }
}

describe("foldConversation", () => {
  it("folds consecutive assistant chunk rows into one turn", () => {
    const folded = foldConversation([
      item("user", "hi"),
      item("assistant", "I"),
      item("assistant", "'ll"),
      item("assistant", " use"),
      item("assistant", " the repo")
    ])
    expect(folded).toHaveLength(2)
    expect(folded[1]).toMatchObject({ role: "assistant", text: "I'll use the repo" })
  })

  it("starts a new turn only on a user message", () => {
    const folded = foldConversation([
      item("assistant", "first"),
      item("user", "follow-up"),
      item("assistant", "second")
    ])
    expect(folded.map((entry) => entry.role)).toEqual(["assistant", "user", "assistant"])
  })

  it("inserts a paragraph break at a messageId boundary within a turn", () => {
    const folded = foldConversation([
      item("assistant", "part one", { messageId: "m1" }),
      item("assistant", " continues", { messageId: "m1" }),
      item("assistant", "part two", { messageId: "m2" })
    ])
    expect(folded).toHaveLength(1)
    expect(folded[0]?.text).toBe("part one continues\n\npart two")
  })

  it("keeps generating state when any merged row is generating", () => {
    const folded = foldConversation([
      item("assistant", "a"),
      item("assistant", "b", { isGenerating: true })
    ])
    expect(folded[0]?.isGenerating).toBe(true)
  })

  it("drops system rows but flushes the turn across them", () => {
    const folded = foldConversation([
      item("assistant", "a"),
      item("system", "boot"),
      item("assistant", "b")
    ])
    expect(folded).toHaveLength(2)
    expect(folded.map((entry) => entry.text)).toEqual(["a", "b"])
  })
})
