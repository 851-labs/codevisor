import type { Harness } from "@codevisor/api"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("@codevisor/db", () => {
  it("applies harness settings, auth tokens, and update state", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "server-a" }))
    const harnesses: ReadonlyArray<Harness> = [
      {
        id: "codex",
        name: "Codex",
        symbolName: "chevron.left.forwardslash.chevron.right",
        source: "registry",
        launchKind: "npx",
        enabled: true,
        readiness: { state: "ready" }
      },
      {
        id: "claude-code",
        name: "Claude Code",
        symbolName: "sparkle",
        source: "registry",
        launchKind: "executable",
        enabled: true,
        readiness: { state: "unavailable", detail: "missing" }
      }
    ]

    expect(await run(db.applyHarnessSettings(harnesses))).toEqual(harnesses)
    await run(db.setHarnessEnabled("codex", false))
    expect(
      (await run(db.applyHarnessSettings(harnesses))).map((harness) => harness.enabled)
    ).toEqual([false, true])
    await run(db.setHarnessEnabled("codex", true))
    expect(
      (await run(db.applyHarnessSettings(harnesses))).map((harness) => harness.enabled)
    ).toEqual([true, true])

    const token = await run(db.issuePairingToken)
    expect(token.startsWith("hm_")).toBe(true)
    expect(await run(db.verifyBearerToken(token))).toBe(true)
    expect(await run(db.verifyBearerToken("hm_wrong"))).toBe(false)

    expect(await run(db.getUpdateInfo)).toMatchObject({
      currentVersion: "0.1.0",
      updateAvailable: false,
      migrationState: "idle"
    })
    const update = await run(
      db.setUpdateInfo({
        currentVersion: "0.1.0",
        latestVersion: "0.2.0",
        updateAvailable: true,
        channel: "development",
        checkedAt: "2026-06-30T01:00:00.000Z",
        migrationState: "running"
      })
    )
    expect(update.updateAvailable).toBe(true)
    expect(await run(db.getUpdateInfo)).toEqual(update)
    expect(
      await run(
        db.setUpdateInfo({
          currentVersion: "0.2.0",
          latestVersion: "0.2.0",
          updateAvailable: false,
          channel: "stable",
          migrationState: "idle"
        })
      )
    ).toEqual({
      currentVersion: "0.2.0",
      latestVersion: "0.2.0",
      updateAvailable: false,
      channel: "stable",
      migrationState: "idle"
    })

    await Effect.runPromise(db.close)
  })

  it("round-trips harness update state and pending updates", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))

    // Latest-version knowledge: empty → upsert (sparse and full) → list.
    expect(await run(db.listHarnessUpdateStates)).toEqual([])
    const sparse = await run(
      db.setHarnessUpdateState({ harnessId: "codex", info: { updateAvailable: false } })
    )
    expect(sparse.info.updateAvailable).toBe(false)
    expect(await run(db.listHarnessUpdateStates)).toEqual([
      { harnessId: "codex", info: { updateAvailable: false } }
    ])
    const full = {
      harnessId: "codex",
      info: {
        updateAvailable: true,
        installedVersion: "0.144.6",
        latestVersion: "0.145.0",
        source: "brew",
        installOrigin: "brew",
        channel: "stable",
        checkedAt: "2026-07-20T00:00:00.000Z"
      }
    }
    await run(db.setHarnessUpdateState(full))
    expect(await run(db.listHarnessUpdateStates)).toEqual([full])

    // Pending updates: empty → armed (sparse) → running (full) → cleared.
    expect(await run(db.listHarnessPendingUpdates)).toEqual([])
    await run(
      db.setHarnessPendingUpdate({
        harnessId: "codex",
        state: "pending",
        requestedAt: "2026-07-20T00:01:00.000Z"
      })
    )
    expect(await run(db.listHarnessPendingUpdates)).toEqual([
      { harnessId: "codex", state: "pending", requestedAt: "2026-07-20T00:01:00.000Z" }
    ])
    const running = {
      harnessId: "codex",
      state: "running" as const,
      targetVersion: "0.145.0",
      requestedAt: "2026-07-20T00:01:00.000Z",
      startedAt: "2026-07-20T00:02:00.000Z",
      timeoutAt: "2026-07-20T00:12:00.000Z"
    }
    expect(await run(db.setHarnessPendingUpdate(running))).toEqual(running)
    expect(await run(db.listHarnessPendingUpdates)).toEqual([running])
    await run(db.clearHarnessPendingUpdate("codex"))
    expect(await run(db.listHarnessPendingUpdates)).toEqual([])
    // Clearing an absent row is a no-op, not an error.
    await run(db.clearHarnessPendingUpdate("codex"))

    await Effect.runPromise(db.close)
  })
})
