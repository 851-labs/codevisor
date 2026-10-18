import { describe, expect, it } from "vitest"

import { makeAntigravityProvider } from "./provider.js"
import { definition, environment, fakeRunner, run } from "./test-support.js"

const USAGE_OUTPUT = [
  "Gemini Models\tFive Hour Limit Remaining\t95%\t2026-10-19T01:00:00Z",
  "Gemini Models\tWeekly Limit Remaining\t60%\t2026-10-25T00:00:00Z",
  "Claude and GPT models\tWeekly Limit Remaining\t100%\tsoon"
].join("\n")

describe("Antigravity usage limits", () => {
  it("turns agy's remaining quota rows into usage windows", async () => {
    const { runner, calls } = fakeRunner({ "-p /usage": { stdout: `${USAGE_OUTPUT}\n` } })
    const provider = makeAntigravityProvider(environment, { runner, usageDeadlineMs: 5_000 })

    const limits = await run(provider.readUsageLimits!(definition, "/repo"))

    expect(calls.at(-1)).toMatchObject({ timeoutMs: 5_000 })
    expect(limits).toMatchObject({
      harnessId: "antigravity",
      state: "available",
      windows: [
        {
          id: "gemini-models-5-hour",
          label: "Gemini Models · 5-hour",
          resetsAt: "2026-10-19T01:00:00.000Z",
          usedPercent: 5
        },
        { id: "gemini-models-weekly", label: "Gemini Models · Weekly", usedPercent: 40 },
        { id: "claude-and-gpt-models-weekly", usedPercent: 0 }
      ]
    })
    expect(limits.windows[2]).not.toHaveProperty("resetsAt")
  })

  it("reports nothing when agy prints something other than usage rows", async () => {
    const signedOut = fakeRunner({
      "-p /usage": { code: 1, stdout: "Authentication required. Please visit the URL to log in:" }
    })
    const timedOut = fakeRunner({ "-p /usage": new Error("Antigravity didn't respond in time.") })
    const changed = fakeRunner({
      "-p /usage": {
        stdout: [
          "Usage\tsomething\tnew",
          "Gemini Models\tDaily Limit Remaining\t50%\t2026-10-19T00:00:00Z",
          "Gemini Models\tWeekly Limit Remaining\t50\t2026-10-19T00:00:00Z",
          "Gemini Models\tWeekly Limit Remaining\tmost%\t2026-10-19T00:00:00Z",
          "\tWeekly Limit Remaining\t50%\t2026-10-19T00:00:00Z"
        ].join("\n")
      }
    })

    for (const { runner } of [signedOut, timedOut, changed]) {
      const provider = makeAntigravityProvider(environment, { runner })
      expect(await run(provider.readUsageLimits!(definition, "/repo"))).toMatchObject({
        state: "unavailable",
        windows: []
      })
    }
  })
})
