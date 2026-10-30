import type { FakePauses } from "@codevisor/sandboxes"
import { describe, expect, it } from "vitest"

import { FAKE_PROFILE, JOINED_DEVICE, ok, sandboxHarness } from "./sandbox-test-support.js"

const request = { profileId: "profile-1", projectId: "project-1", name: "Idle box" }
const minute = 60 * 1000

const readySandbox = async (
  pauses: FakePauses,
  pauseAfter = "30",
  options: Parameters<typeof sandboxHarness>[0] = {}
) => {
  const harness = await sandboxHarness({ ...options, pauses })
  await harness.settings.putProfile({ ...FAKE_PROFILE, values: { size: "small", pauseAfter } })
  await harness.machines.create(request)
  await harness.machines.settled()
  const tick = async (minutes: number) => {
    await harness.deps.clock.sleep(minutes * minute)
    await harness.machines.watch()
    await harness.machines.settled()
  }
  const chatting = (state: string) => {
    harness.controls.answer = (tool) =>
      tool === "codevisor.agents.list" ? { items: [{ agentId: "a", state }] } : undefined
  }
  const record = async () => harness.records.get("id-1")
  return { ...harness, tick, chatting, record }
}

describe("pausing an idle sandbox", () => {
  it("pauses once no chat has run for the profile's Pause after, not a minute sooner", async () => {
    const harness = await readySandbox("in-place")

    await harness.tick(29)
    const awake = await harness.record()
    await harness.tick(1)

    expect(awake).toMatchObject({ state: "ready" })
    expect(awake?.power).toBeUndefined()
    expect(await harness.record()).toMatchObject({ state: "ready", power: "paused" })
    expect(harness.provider.machines.get("fake-1")?.state).toBe("stopped")
  })

  it("counts idle time from the last running turn, including one waiting on a question", async () => {
    const harness = await readySandbox("in-place", "15")

    harness.chatting("working")
    await harness.tick(10)
    harness.chatting("waitingForUser")
    await harness.tick(10)
    harness.chatting("idle")
    await harness.tick(14)
    const stillAwake = await harness.record()
    await harness.tick(1)

    expect(stillAwake?.power).toBeUndefined()
    expect(stillAwake?.lastActiveAt).toBe("2026-10-23T00:20:00.000Z")
    expect(await harness.record()).toMatchObject({ power: "paused" })
  })

  it("counts a turn too quick to see running by its chat's last update", async () => {
    const harness = await readySandbox("in-place", "15")
    harness.controls.answer = (tool) =>
      tool === "codevisor.agents.list"
        ? { items: [{ agentId: "a", state: "idle", updatedAt: "2026-10-23T00:10:00.000Z" }] }
        : undefined

    await harness.tick(24)
    const stillAwake = await harness.record()
    await harness.tick(1)

    expect(stillAwake?.power).toBeUndefined()
    expect(stillAwake?.lastActiveAt).toBe("2026-10-23T00:10:00.000Z")
    expect(await harness.record()).toMatchObject({ power: "paused" })
  })

  it("never pauses with Never, and keeps extending the provider's timeout an hour ahead", async () => {
    const harness = await readySandbox("in-place", "never")

    for (let hour = 0; hour < 5; hour += 1) await harness.tick(30)

    expect((await harness.record())?.power).toBeUndefined()
    expect(harness.provider.keptAlive.map((call) => new Date(call.untilMs).toISOString())).toEqual([
      "2026-10-23T01:30:00.000Z",
      "2026-10-23T02:30:00.000Z",
      "2026-10-23T03:30:00.000Z"
    ])
  })

  it("leaves a paused sandbox alone even after its provider machine is gone", async () => {
    const harness = await readySandbox("snapshot")

    await harness.tick(30)
    await harness.tick(60)

    expect(await harness.record()).toMatchObject({
      state: "ready",
      power: "paused",
      providerMachineId: "fake-1",
      pausedSnapshot: "snapshot-of-fake-1"
    })
    expect(harness.provider.machines.size).toBe(0)
  })
})

describe("waking a sandbox", () => {
  it("answers waking at once, then restarts its Codevisor and gives it a fresh idle window", async () => {
    const harness = await readySandbox("in-place")
    await harness.tick(30)

    const waking = await harness.machines.wake("id-1")
    await harness.machines.settled()

    expect(waking).toMatchObject({ id: "id-1", power: "waking" })
    const woken = await harness.record()
    expect(woken).toMatchObject({
      providerMachineId: "fake-1",
      lastActiveAt: "2026-10-23T00:30:00.000Z"
    })
    expect(woken?.power).toBeUndefined()
    expect(harness.provider.machines.get("fake-1")?.state).toBe("running")
    expect(harness.curls.at(-1)?.script).toContain('codevisor" start')
  })

  it("stays waking until the sandbox is back online, and gives up waiting after three minutes", async () => {
    const harness = await readySandbox("in-place")
    await harness.tick(30)
    const joined = harness.presences.find((entry) => entry.deviceId === JOINED_DEVICE)
    if (joined === undefined) throw new Error("no sandbox presence")
    harness.presences.splice(harness.presences.indexOf(joined), 1, { ...joined, online: false })
    const before = harness.deps.clock.now()

    await harness.machines.wake("id-1")
    await harness.machines.settled()

    expect(harness.deps.clock.now() - before).toBe(3 * minute)
    expect((await harness.record())?.power).toBeUndefined()
    expect(harness.logs).toContain("Sandbox Idle box (id-1) woke but hasn't come back online yet")
  })

  it("wakes a snapshot provider on a new machine from its snapshot", async () => {
    const harness = await readySandbox("snapshot")
    await harness.tick(30)

    await harness.machines.wake("id-1")
    await harness.machines.settled()

    const woken = await harness.record()
    expect(woken).toMatchObject({ providerMachineId: "fake-1-from-snapshot-of-fake-1" })
    expect(woken?.power).toBeUndefined()
    expect(woken?.pausedSnapshot).toBeUndefined()
  })

  it("stays paused, and drops the new machine, when Codevisor won't start on it", async () => {
    const harness = await readySandbox("snapshot", "30", {
      onCurl: (curl) =>
        curl.script.includes('codevisor" start')
          ? { exitCode: 1, stdout: "", stderr: "no server" }
          : ok()
    })
    await harness.tick(30)

    await harness.machines.wake("id-1")
    await harness.machines.settled()

    expect(await harness.record()).toMatchObject({
      power: "paused",
      providerMachineId: "fake-1",
      pausedSnapshot: "snapshot-of-fake-1"
    })
    expect(harness.provider.machines.size).toBe(0)
    expect(harness.logs.at(-1)).toBe(
      "Waking sandbox Idle box failed: Codevisor didn't start: no server"
    )
  })

  it("leaves a running sandbox as it is", async () => {
    const harness = await readySandbox("in-place")

    expect(await harness.machines.wake("id-1")).toMatchObject({ id: "id-1", state: "ready" })
    expect((await harness.record())?.power).toBeUndefined()
  })

  it("restarts a snapshot provider's sandbox before the provider's hard cap ends it", async () => {
    const harness = await readySandbox("snapshot", "240")
    const running = await harness.record()
    if (running === undefined) throw new Error("no sandbox")
    harness.chatting("working")
    await harness.records.put({ ...running, expiresAt: "2026-10-23T00:45:00.000Z" })

    await harness.tick(10)
    const before = await harness.record()
    await harness.tick(10)

    expect(before?.providerMachineId).toBe("fake-1")
    expect(await harness.record()).toMatchObject({
      providerMachineId: "fake-1-from-snapshot-of-fake-1"
    })
    expect(harness.logs).toContain("Restarting sandbox Idle box (id-1) before its provider ends it")
  })
})

describe("a sandbox its provider paused on its own", () => {
  it("is woken while it still has idle time left, and marked paused once it doesn't", async () => {
    const harness = await readySandbox("in-place")
    const machine = harness.provider.machines.get("fake-1")
    if (machine === undefined) throw new Error("no machine")

    machine.state = "stopped"
    await harness.tick(10)
    const woken = await harness.record()
    machine.state = "stopped"
    await harness.tick(30)

    expect(woken?.power).toBeUndefined()
    expect(await harness.record()).toMatchObject({ power: "paused" })
    expect(harness.provider.machines.get("fake-1")?.state).toBe("stopped")
  })
})
