import type { ExecRequest } from "@codevisor/sandboxes"
import type { SyncEntryRecord } from "@codevisor/sync"
import { describe, expect, it } from "vitest"

import { run } from "../server-context.js"
import { field } from "../unknown-values.js"
import { FAKE_PROFILE, ok, sandboxHarness } from "./sandbox-test-support.js"

const request = { profileId: "profile-1", projectId: "project-1", name: "Idle box" }
const minute = 60 * 1000
const sharedAccountsPut = "-X 'PUT'"
const sharedAccountsUrl = "/v1/sync/harness-shared-accounts'"

const signIn = (wallMs: number, credentialId: string) => ({
  key: "shared-claude-account",
  value: { id: "shared-claude-account", credential: { id: credentialId } },
  timestamp: { wallMs, counter: 0, deviceId: "owner" }
})

const readySandbox = async (options: Parameters<typeof sandboxHarness>[0] = {}) => {
  const harness = await sandboxHarness({ ...options, pauses: "in-place" })
  await harness.settings.putProfile({
    ...FAKE_PROFILE,
    values: { size: "small", pauseAfter: "30" }
  })
  await run(
    harness.services.db.mergeSyncEntries("harness-shared-accounts", [signIn(1, "old-grant")])
  )
  await harness.machines.create(request)
  await harness.machines.settled()
  const tick = async (minutes: number) => {
    await harness.deps.clock.sleep(minutes * minute)
    await harness.machines.watch()
    await harness.machines.settled()
  }
  const reLogin = (wallMs: number, credentialId: string) =>
    run(
      harness.services.db.mergeSyncEntries("harness-shared-accounts", [
        signIn(wallMs, credentialId)
      ])
    )
  const sentGrants = () => harness.curls.filter(isSharedAccountsPut).map(grantIn)
  return { ...harness, tick, reLogin, sentGrants }
}

const powerIn = (entries: ReadonlyArray<SyncEntryRecord> | undefined): unknown =>
  field(entries?.at(-1)?.value, "power")

const isSharedAccountsPut = (curl: ExecRequest): boolean =>
  curl.script.includes(sharedAccountsPut) && curl.script.includes(sharedAccountsUrl)

const grantIn = (curl: ExecRequest): unknown => {
  const body: unknown = JSON.parse(curl.stdin ?? "{}")
  const [entry] = asArray(field(body, "entries"))
  return field(field(field(entry, "value"), "credential"), "id")
}

const asArray = (value: unknown): ReadonlyArray<unknown> => (Array.isArray(value) ? value : [])

describe("harness sign-ins on a running sandbox", () => {
  it("sends a re-login to the sandbox on the next check, and nothing while sign-ins are unchanged", async () => {
    const harness = await readySandbox()

    await harness.tick(1)
    const beforeReLogin = harness.sentGrants()
    await harness.reLogin(2, "new-grant")
    await harness.tick(1)
    await harness.tick(1)

    expect(beforeReLogin).toEqual(["old-grant"])
    expect(harness.sentGrants()).toEqual(["old-grant", "new-grant"])
    expect(harness.logs).toContain("Sandbox Idle box (id-1): refreshed harness sign-ins")
  })

  it("tries again on the next check when the sandbox couldn't take them", async () => {
    let failing = true
    const harness = await readySandbox({
      onCurl: (curl) =>
        failing && isSharedAccountsPut(curl) && curl.stdin?.includes("new-grant") === true
          ? { exitCode: 7, stdout: "", stderr: "curl: (7) Failed to connect" }
          : ok()
    })

    await harness.reLogin(2, "new-grant")
    await harness.tick(1)
    failing = false
    await harness.tick(1)

    expect(harness.logs).toContain(
      "Refreshing harness sign-ins on sandbox Idle box failed: PUT /v1/sync/harness-shared-accounts failed on the sandbox: curl: (7) Failed to connect"
    )
    expect(harness.sentGrants()).toEqual(["old-grant", "new-grant", "new-grant"])
  })
})

describe("harness sign-ins on a waking sandbox", () => {
  it("sends the latest sign-ins before the sandbox stops waking", async () => {
    const powerWhenSent: unknown[] = []
    let changes: ReadonlyArray<ReadonlyArray<SyncEntryRecord>> = []
    const harness = await readySandbox({
      onCurl: (curl) => {
        if (isSharedAccountsPut(curl)) powerWhenSent.push(powerIn(changes.at(-1)))
        return ok()
      }
    })
    changes = harness.changes
    await harness.tick(30)
    await harness.reLogin(2, "new-grant")

    await harness.machines.wake("id-1")
    await harness.machines.settled()

    expect(harness.sentGrants()).toEqual(["old-grant", "new-grant"])
    expect(powerWhenSent.at(-1)).toBe("waking")
    expect((await harness.records.get("id-1"))?.power).toBeUndefined()
  })

  it("still wakes when the sign-ins can't be sent", async () => {
    const harness = await readySandbox({
      onCurl: (curl) =>
        isSharedAccountsPut(curl) && curl.stdin?.includes("new-grant") === true
          ? { exitCode: 7, stdout: "", stderr: "curl: (7) Failed to connect" }
          : ok()
    })
    await harness.tick(30)
    await harness.reLogin(2, "new-grant")

    await harness.machines.wake("id-1")
    await harness.machines.settled()

    expect((await harness.records.get("id-1"))?.power).toBeUndefined()
    expect(harness.logs).toContain(
      "Refreshing harness sign-ins on sandbox Idle box failed: PUT /v1/sync/harness-shared-accounts failed on the sandbox: curl: (7) Failed to connect"
    )
  })
})
