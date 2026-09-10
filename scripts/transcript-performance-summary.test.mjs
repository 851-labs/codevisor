import assert from "node:assert/strict"
import test from "node:test"
import { summarizeTranscriptPerformance } from "./transcript-performance-summary.mjs"

test("reports independent timing distributions and the latest viewport", () => {
  const records = [20, 2, 10, 4].map((durationMS) => ({ name: "ios.mount", durationMS }))
  records.push(
    { name: "frame", durationMS: 0.125 },
    { name: "ios.mount", durationMS: Number.NaN },
    { name: "ios.viewport", values: { anchor: 12, anchorOffset: 30, follow: 0 } },
    { name: "ios.viewport", values: { anchor: 12, anchorOffset: 30, follow: 0, ready: 1 } }
  )
  assert.deepEqual(summarizeTranscriptPerformance(records), {
    timings: {
      frame: { count: 1, p50MS: 0.125, p95MS: 0.125, maxMS: 0.125 },
      "ios.mount": { count: 4, p50MS: 4, p95MS: 20, maxMS: 20 }
    },
    viewports: { "ios.viewport": { anchor: 12, anchorOffset: 30, follow: 0, ready: 1 } }
  })
  assert.deepEqual(summarizeTranscriptPerformance([]), { timings: {}, viewports: {} })
})
