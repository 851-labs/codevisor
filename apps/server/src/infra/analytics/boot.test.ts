import { Effect } from "effect"
import { afterEach, describe, expect, it } from "vitest"

import { startServerAnalytics } from "./boot.js"
import { installServerAnalytics, serverAnalyticsInstalled } from "./server-analytics.js"

const db = { getSyncEntries: () => Effect.succeed([]) }

afterEach(() => installServerAnalytics(undefined))

describe("server analytics boot", () => {
  it("stays off in development unless analytics is asked for", () => {
    startServerAnalytics({
      db,
      serverId: "s",
      version: "1",
      env: { CODEVISOR_DEV_INSTANCE_ID: "dev" }
    })
    expect(serverAnalyticsInstalled()).toBe(false)

    startServerAnalytics({
      db,
      serverId: "s",
      version: "1",
      env: { CODEVISOR_DEV_INSTANCE_ID: "dev", CODEVISOR_ENABLE_ANALYTICS: "1" }
    })
    expect(serverAnalyticsInstalled()).toBe(true)
  })
})
