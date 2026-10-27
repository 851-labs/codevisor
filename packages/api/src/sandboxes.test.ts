import { describe, expect, it } from "vitest"

import { SANDBOXES_FEATURE_FLAG, sandboxesFlagOn } from "./sandboxes.js"

const flag = (value: unknown, deleted?: boolean) => ({
  key: SANDBOXES_FEATURE_FLAG.key,
  value,
  ...(deleted === undefined ? {} : { deleted })
})

describe("the sandboxes developer flag", () => {
  it("is on only when its synced preference is true and not deleted", () => {
    expect(sandboxesFlagOn([flag(true)])).toBe(true)
    expect(sandboxesFlagOn([])).toBe(false)
    expect(sandboxesFlagOn([flag(false)])).toBe(false)
    expect(sandboxesFlagOn([flag(true, true)])).toBe(false)
    expect(sandboxesFlagOn([{ key: "featureFlags.bots", value: true }])).toBe(false)
  })
})
