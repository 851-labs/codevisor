import { describe, expect, it } from "vitest"

import { composerDraftText, rememberComposerDraftText } from "./useComposerDraftText"

describe("composer draft text cache", () => {
  it("keeps drafts isolated by session and clears empty drafts", () => {
    rememberComposerDraftText("draft-session-a", "Follow up in A")
    rememberComposerDraftText("draft-session-b", "Follow up in B")

    expect(composerDraftText("draft-session-a")).toBe("Follow up in A")
    expect(composerDraftText("draft-session-b")).toBe("Follow up in B")

    rememberComposerDraftText("draft-session-a", "")
    expect(composerDraftText("draft-session-a")).toBeUndefined()
    expect(composerDraftText("draft-session-b")).toBe("Follow up in B")
  })

  it("bounds retained drafts", () => {
    for (let index = 0; index < 65; index += 1) {
      rememberComposerDraftText(`bounded-draft-${index}`, `Draft ${index}`)
    }

    expect(composerDraftText("bounded-draft-0")).toBeUndefined()
    expect(composerDraftText("bounded-draft-64")).toBe("Draft 64")
  })
})
