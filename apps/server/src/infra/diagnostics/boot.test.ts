import type { SyncEntryRecord } from "@codevisor/sync"
import { Effect } from "effect"
import { afterEach, describe, expect, it } from "vitest"

import { startServerDiagnostics } from "./boot.js"
import { installServerDiagnostics, serverDiagnosticsInstalled } from "./server-diagnostics.js"

const timestamp = { wallMs: 1, counter: 0, deviceId: "mac" }

const database = (entries: ReadonlyArray<Omit<SyncEntryRecord, "timestamp">>) => ({
  getSyncEntries: () => Effect.succeed(entries.map((entry) => ({ ...entry, timestamp })))
})

afterEach(() => installServerDiagnostics(undefined))

describe("server diagnostics boot", () => {
  it("stays off in development unless diagnostics are asked for", () => {
    const db = database([])
    startServerDiagnostics({ db, version: "1.0.0", env: { CODEVISOR_DEV_INSTANCE_ID: "dev" } })
    expect(serverDiagnosticsInstalled()).toBe(false)

    startServerDiagnostics({
      db,
      version: "1.0.0",
      env: { CODEVISOR_DEV_INSTANCE_ID: "dev", CODEVISOR_ENABLE_DIAGNOSTICS: "1" }
    })
    expect(serverDiagnosticsInstalled()).toBe(true)
  })

  it("stays off when the DSN override is unusable", () => {
    startServerDiagnostics({
      db: database([]),
      version: undefined,
      env: { CODEVISOR_SENTRY_DSN: "nope" }
    })
    expect(serverDiagnosticsInstalled()).toBe(false)
  })
})
