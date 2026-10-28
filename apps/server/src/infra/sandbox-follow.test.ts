import { describe, expect, it } from "vitest"

import { HttpFailure } from "../server-context.js"
import { readyHarness, sandboxHarness } from "./sandbox-test-support.js"

const request = { profileId: "profile-1", projectId: "project-1", name: "Spike box" }

const failed = async (extra: Record<string, unknown> = {}) => {
  const harness = await sandboxHarness({ onCurl: readyHarness("codex") })
  harness.controls.createFails = true
  await harness.machines.create({ ...request, ...extra })
  await harness.machines.settled()
  harness.controls.createFails = false
  return harness
}

const statusOf = (cause: unknown): number | undefined =>
  cause instanceof HttpFailure ? cause.status : undefined

describe("following a sandbox", () => {
  it("reads one sandbox, and answers 404 for one that doesn't exist", async () => {
    const harness = await sandboxHarness()
    await harness.machines.create(request)

    expect(await harness.machines.get("id-1")).toMatchObject({ id: "id-1", state: "creating" })
    expect(statusOf(await harness.machines.get("nope").catch((cause) => cause))).toBe(404)
    await harness.machines.settled()
  })

  it("keeps the start log with the invite redacted, and still publishes each line", async () => {
    const harness = await sandboxHarness()
    const published: string[] = []

    await harness.machines.create(request, async (log) => {
      published.push(log.line)
    })
    await harness.machines.settled()

    const lines = await harness.machines.log("id-1")
    expect(lines.map((log) => log.line)).toEqual(published)
    expect(lines).toContainEqual({
      machineId: "id-1",
      stage: "signIn",
      stream: "stdout",
      line: "joined"
    })
    expect(JSON.stringify(lines)).not.toContain("secret-invite-token")
    expect(await harness.machines.log("id-1", 1)).toEqual(lines.slice(-1))
    expect(statusOf(await harness.machines.log("nope").catch((cause) => cause))).toBe(404)
  })
})

describe("waiting for a sandbox", () => {
  it("returns once the sandbox is ready, and right away once it has failed", async () => {
    const harness = await sandboxHarness()
    await harness.machines.create(request)

    const ready = await harness.machines.wait("id-1", 60_000)
    harness.controls.createFails = true
    await harness.machines.create({ ...request, id: "broken" })
    await harness.machines.settled()
    const broken = await harness.machines.wait("broken", 0)

    expect(ready).toMatchObject({ id: "id-1", state: "ready", timedOut: false })
    expect(broken).toMatchObject({ id: "broken", state: "failed", timedOut: false })
  })

  it("says it timed out while the sandbox is still setting up, polling once a second", async () => {
    const harness = await sandboxHarness()
    const started = await harness.machines.create(request)
    await harness.machines.settled()
    await harness.records.put(started)
    const before = harness.deps.clock.now()

    const waited = await harness.machines.wait("id-1", 2500)

    expect(waited).toMatchObject({ state: "creating", timedOut: true })
    expect(harness.deps.clock.now() - before).toBe(2500)
  })

  it("answers 404 when the sandbox is gone", async () => {
    const harness = await sandboxHarness()

    expect(statusOf(await harness.machines.wait("nope", 0).catch((cause) => cause))).toBe(404)
  })
})

describe("retrying a sandbox", () => {
  it("starts a failed sandbox again under the same id with the same project and agent", async () => {
    const agent = { prompt: "Fix it", title: "Fix", harness: "codex" }
    const harness = await failed({ agent })

    const restarted = await harness.machines.retry("id-1")
    await harness.machines.settled()

    expect(restarted).toMatchObject({ id: "id-1", state: "creating", agent, harnessId: "codex" })
    expect(await harness.machines.get("id-1")).toMatchObject({
      state: "ready",
      agentId: "remote-agent"
    })
  })

  it("keeps the workspace a failed sandbox was started for", async () => {
    const harness = await failed({ workspaceId: "CHAT-WS" })

    const restarted = await harness.machines.retry("id-1")
    await harness.machines.settled()

    expect(restarted.workspaceId).toBe("chat-ws")
  })

  it("keeps waiting for the workspace when the failed sandbox deferred it", async () => {
    const harness = await failed({ defersWorkspace: true })

    const restarted = await harness.machines.retry("id-1")
    await harness.machines.settled()

    expect(restarted.defersWorkspace).toBe(true)
  })

  it("refuses a sandbox that hasn't failed or has no profile to start from", async () => {
    const harness = await sandboxHarness()
    await harness.machines.create(request)
    await harness.machines.settled()
    const ready = await harness.machines.get("id-1")
    await harness.records.put({ ...ready, id: "orphan", state: "failed", profileId: undefined })

    const running = await harness.machines.retry("id-1").catch((cause) => cause)
    const orphan = await harness.machines.retry("orphan").catch((cause) => cause)

    expect([statusOf(running), statusOf(orphan)]).toEqual([409, 409])
    expect(String(running)).toContain("Spike box hasn't failed")
    expect(String(orphan)).toContain("Spike box has no profile to start from again")
  })

  it("puts the failed sandbox back when it can't start again", async () => {
    const harness = await failed()
    await harness.settings.removeProfile("profile-1")

    const refused = await harness.machines.retry("id-1").catch((cause) => cause)

    expect(statusOf(refused)).toBe(404)
    expect(await harness.machines.get("id-1")).toMatchObject({
      state: "failed",
      error: "quota exceeded"
    })
  })
})
