import { describe, expect, it } from "vitest"

import { transcriptRestoreTarget, type TranscriptScrollState } from "./Transcript"

const saved: TranscriptScrollState = {
  scrollTop: 320,
  anchorItemId: "message-2",
  anchorDelta: -24,
  isAtBottom: false
}

describe("transcript scroll restoration", () => {
  it("restores against the message anchor when content above changed height", () => {
    expect(transcriptRestoreTarget(saved, 500)).toBe(524)
  })

  it("falls back to the raw offset when the anchor no longer exists", () => {
    expect(transcriptRestoreTarget(saved, undefined)).toBe(320)
  })

  it("never restores above the beginning of the transcript", () => {
    expect(transcriptRestoreTarget({ ...saved, anchorDelta: 40 }, 12)).toBe(0)
  })
})
