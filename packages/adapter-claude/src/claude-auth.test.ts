import { describe, expect, it } from "vitest"
import { spawnClaudeAuthClient } from "./claude-auth.js"

const makeClient = (overrides: Record<string, unknown> = {}) => {
  const calls: Array<Array<unknown>> = []
  const fake = {
    claudeAuthenticate: async (loginWithClaudeAi: boolean) => {
      calls.push(["authenticate", loginWithClaudeAi])
      return { automaticUrl: "https://auto.example", manualUrl: "https://manual.example" }
    },
    claudeOAuthCallback: async (code: string, state: string) => {
      calls.push(["callback", code, state])
      return {}
    },
    claudeOAuthWaitForCompletion: async () => {
      calls.push(["wait"])
      // Claude clears its active flow before the callback resolves.
      throw new Error("No active claude_authenticate flow")
    },
    interrupt: async () => {
      calls.push(["interrupt"])
    },
    close: () => {
      calls.push(["close"])
    },
    ...overrides
  }
  const client = spawnClaudeAuthClient({
    claudePath: "/usr/local/bin/claude",
    cwd: "/tmp",
    env: {},
    queryFn: (() => fake) as never
  })
  return { calls, client }
}

describe("spawnClaudeAuthClient", () => {
  it("completes the pasted exchange after Claude clears its active flow", async () => {
    const { calls, client } = makeClient()
    expect(await client.start()).toEqual({ url: "https://manual.example" })
    await expect(client.submit(" the-code#the-state ")).resolves.toBeUndefined()
    expect(calls).toContainEqual(["callback", "the-code", "the-state"])
    client.close()
    expect(calls).toContainEqual(["interrupt"])
    expect(calls).toContainEqual(["close"])
  })

  it("waits for the callback to finish saving credentials before completing", async () => {
    const entered = Promise.withResolvers<void>()
    const saved = Promise.withResolvers<void>()
    const { client } = makeClient({
      claudeOAuthCallback: async () => {
        entered.resolve()
        await saved.promise
      }
    })
    await client.start()
    let settled = false
    const submitted = client.submit("the-code#the-state").finally(() => {
      settled = true
    })
    const completed = expect(submitted).resolves.toBeUndefined()
    try {
      await entered.promise
      expect(settled).toBe(false)
    } finally {
      saved.resolve()
      await completed
      client.close()
    }
  })

  it.each(["Invalid authorization code", "No active claude_authenticate flow"])(
    "preserves callback failure: %s",
    async (message) => {
      const failure = new Error(message)
      const { client } = makeClient({
        claudeOAuthCallback: async () => {
          throw failure
        }
      })
      await client.start()
      await expect(client.submit("the-code#the-state")).rejects.toBe(failure)
      client.close()
    }
  )

  it("falls back to the automatic URL and tolerates a bare code", async () => {
    const { calls, client } = makeClient({
      claudeAuthenticate: async () => ({ automaticUrl: "https://auto.example" })
    })
    expect(await client.start()).toEqual({ url: "https://auto.example" })
    await client.submit("solo-code")
    expect(calls).toContainEqual(["callback", "solo-code", ""])
  })

  it("refuses a missing URL and an empty paste", async () => {
    const { client } = makeClient({ claudeAuthenticate: async () => ({}) })
    await expect(client.start()).rejects.toThrow("did not provide a sign-in URL")
    await expect(client.submit("   ")).rejects.toThrow("Paste the code")
  })

  it("closes without optional teardown hooks and swallows interrupt failures", async () => {
    const { client } = makeClient({ interrupt: undefined, close: undefined })
    client.close()
    const failing = makeClient({
      interrupt: () => Promise.reject(new Error("gone"))
    })
    failing.client.close()
  })
})
