import { describe, expect, it } from "vitest"

import { cursorAccessToken, cursorAuthFilePath, type CursorCredentialStore } from "./credentials.js"
import { readCursorUsageLimits, type CursorFetch } from "./usage.js"

const weekStart = Date.parse("2026-11-19T03:49:46.269Z")
const weekEnd = Date.parse("2026-11-26T03:49:46.269Z")

const currentPeriod = (planUsage: Record<string, unknown>) => ({
  billingCycleStart: String(weekStart),
  billingCycleEnd: String(weekEnd),
  planUsage,
  spendLimitUsage: { limitType: "user" },
  enabled: true,
  displayMessage: "You've used 1% of your included usage"
})

const planInfo = {
  planInfo: {
    planName: "Ultra",
    includedUsagePeriod: "INCLUDED_USAGE_PERIOD_WEEKLY",
    includedUsageResetsAt: String(weekEnd)
  }
}

const dashboard =
  (responses: Record<string, Response | Error>): CursorFetch =>
  async (url, init) => {
    expect(init.headers).toMatchObject({ authorization: "Bearer token-1" })
    const response = responses[url.slice(url.lastIndexOf("/") + 1)]
    if (response instanceof Error) throw response
    return response ?? new Response("{}", { status: 404 })
  }

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status })

const read = (fetch: CursorFetch, token: string | undefined = "token-1") =>
  readCursorUsageLimits({ accessToken: async () => token, fetch })

describe("readCursorUsageLimits", () => {
  it("reports the plan and its included usage window from Cursor's dashboard", async () => {
    const limits = await read(
      dashboard({
        GetCurrentPeriodUsage: json(currentPeriod({ autoPercentUsed: 0.8, totalPercentUsed: 0.8 })),
        GetPlanInfo: json(planInfo)
      })
    )
    expect(limits).toMatchObject({
      harnessId: "cursor",
      plan: "Ultra",
      state: "available",
      windows: [
        {
          id: "included",
          label: "Weekly usage",
          usedPercent: 0.8,
          durationMinutes: 10_080,
          resetsAt: "2026-11-26T03:49:46.269Z"
        }
      ]
    })
  })

  it("splits Auto and API model usage when Cursor reports both", async () => {
    const limits = await read(
      dashboard({
        GetCurrentPeriodUsage: json(
          currentPeriod({ autoPercentUsed: 12, apiPercentUsed: 40, totalPercentUsed: 30 })
        ),
        GetPlanInfo: new Error("offline")
      })
    )
    expect(limits.plan).toBeUndefined()
    expect(limits.windows.map((window) => [window.label, window.usedPercent])).toEqual([
      ["Included usage", 30],
      ["Auto", 12],
      ["API models", 40]
    ])
  })

  it("asks for sign-in without a stored login or when Cursor rejects it", async () => {
    const rejected = dashboard({ GetCurrentPeriodUsage: json({}, 401), GetPlanInfo: json({}, 401) })
    for (const limits of [await read(rejected, undefined), await read(rejected)]) {
      expect(limits).toMatchObject({
        state: "unavailable",
        detail: "Sign in to Cursor to see its usage.",
        windows: []
      })
    }
  })

  it("stays unavailable when Cursor can't be reached or reports no plan usage", async () => {
    const offline = await read(dashboard({ GetCurrentPeriodUsage: new Error("offline") }))
    expect(offline).toMatchObject({
      state: "unavailable",
      detail: "Cursor usage is unavailable right now."
    })

    const empty = await read(dashboard({ GetCurrentPeriodUsage: json({ enabled: false }) }))
    expect(empty).toMatchObject({ state: "unavailable", windows: [] })
  })
})

const store = (
  platform: NodeJS.Platform,
  files: Record<string, string>,
  keychain?: string
): CursorCredentialStore => ({
  platform,
  env: { HOME: "/home/person", XDG_CONFIG_HOME: "/xdg" },
  readKeychain: async (service, account) =>
    service === "cursor-access-token" && account === "cursor-user" ? keychain : undefined,
  readText: async (path) => files[path]
})

describe("cursorAccessToken", () => {
  it("reads the Keychain on macOS before Cursor's auth file", async () => {
    const file = { "/home/person/.cursor/auth.json": JSON.stringify({ accessToken: "from-file" }) }
    expect(await cursorAccessToken(store("darwin", file, "from-keychain"))).toBe("from-keychain")
    expect(await cursorAccessToken(store("darwin", file))).toBe("from-file")
  })

  it("reads Cursor's auth file where the CLI keeps it on Linux", async () => {
    expect(cursorAuthFilePath("linux", { HOME: "/home/person" })).toBe(
      "/home/person/.config/cursor/auth.json"
    )
    const files = { "/xdg/cursor/auth.json": JSON.stringify({ accessToken: "linux-token" }) }
    expect(await cursorAccessToken(store("linux", files, "ignored"))).toBe("linux-token")
    expect(await cursorAccessToken(store("linux", { "/xdg/cursor/auth.json": "not json" }))).toBe(
      undefined
    )
  })
})
