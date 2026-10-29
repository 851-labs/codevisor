import {
  encodeCloudFrame,
  ROLE_LEASE_MS,
  ROLE_RENEW_MS,
  ROLE_STABLE_MS,
  ROLES_FEATURE,
  type HubToMachine,
  type RoleAvailability
} from "@codevisor/api"
import { runInDurableObject, SELF } from "cloudflare:test"
import { describe, expect, it, vi } from "vitest"
import { z } from "zod"

import {
  BASE,
  connectMachine,
  disconnect,
  hasTag,
  hubStub,
  type MachineSetup
} from "./cloud-test-support.js"
import { signUpUser } from "./inbox-test-support.js"
import { readJson } from "./json-test-support.js"

const ROLE = "sandbox-manager"

type RoleFrame = Extract<HubToMachine, { t: "role-holders" | "role-lease" }>

const nextRoleFrame = async <Tag extends RoleFrame["t"]>(
  machine: MachineSetup,
  t: Tag
): Promise<Extract<HubToMachine, { t: Tag }>> => {
  for (;;) {
    const frame = await machine.reader.next()
    if (hasTag(frame, t)) return frame
  }
}

const join = async (
  token: string,
  name: string,
  availability: RoleAvailability,
  deviceId?: string
): Promise<MachineSetup> => {
  const machine = await connectMachine(token, name, deviceId)
  machine.socket.send(
    encodeCloudFrame({ t: "role-members", availability, candidate: [ROLE], watch: [] })
  )
  return machine
}

const holderSeenBy = async (machine: MachineSetup) =>
  (await nextRoleFrame(machine, "role-holders")).roles.find((role) => role.role === ROLE)

const renew = async (machine: MachineSetup, version: number, seq: number) => {
  machine.socket.send(encodeCloudFrame({ t: "role-renew", role: ROLE, version, seq }))
  return nextRoleFrame(machine, "role-lease")
}

const holdUntil = async (machine: MachineSetup, version: number, until: number) => {
  for (let seq = 100; Date.now() + ROLE_RENEW_MS < until; seq += 1) {
    vi.setSystemTime(Date.now() + ROLE_RENEW_MS)
    expect(await renew(machine, version, seq)).toMatchObject({ held: true })
  }
}

const runAlarmAt = async (token: string, time: number): Promise<void> => {
  const stub = await hubStub(token)
  await runInDurableObject(stub, async (hub) => {
    vi.setSystemTime(time)
    await hub.alarm()
  })
}

const RolesBody = z.object({
  roles: z.array(
    z.object({
      role: z.string(),
      version: z.number(),
      holder: z.string().optional(),
      handingOff: z.boolean().optional(),
      candidates: z.array(
        z.object({
          deviceId: z.string(),
          availability: z.string(),
          online: z.boolean(),
          recentDrops: z.number(),
          rank: z.number().optional()
        })
      )
    })
  )
})

const roleStatus = async (machine: MachineSetup) => {
  const response = await SELF.fetch(`${BASE}/api/machine/roles`, {
    headers: { "x-api-key": machine.apiKey }
  })
  expect(response.status).toBe(200)
  return (await readJson(response, RolesBody)).roles.find((role) => role.role === ROLE)
}

describe("hub roles", () => {
  it("advertises roles to machines and grants the first candidate a lease only it can renew", async () => {
    const token = await signUpUser()
    const laptop = await join(token, "Laptop", "portable")
    const desktop = await join(token, "Desktop", "always-on")

    expect(laptop.welcome.features).toContain(ROLES_FEATURE)
    expect(await holderSeenBy(laptop)).toEqual({ role: ROLE, version: 1, holder: laptop.deviceId })
    expect(await holderSeenBy(desktop)).toEqual({
      role: ROLE,
      version: 1,
      holder: laptop.deviceId
    })
    expect(await renew(laptop, 1, 1)).toMatchObject({ held: true, seq: 1, leaseMs: ROLE_LEASE_MS })
    expect(await renew(desktop, 1, 1)).toMatchObject({ held: false })
  })

  it("fails over to the next online candidate once a dropped holder's lease lapses", async () => {
    const token = await signUpUser()
    const desktop = await join(token, "Desktop", "always-on")
    expect((await holderSeenBy(desktop))?.holder).toBe(desktop.deviceId)
    const laptop = await join(token, "Laptop", "portable")
    await holderSeenBy(laptop)
    const start = Date.now()

    await disconnect(token, desktop.socket, "asleep")
    await runAlarmAt(token, start + ROLE_LEASE_MS - 1)
    expect((await roleStatus(laptop))?.holder).toBe(desktop.deviceId)
    await runAlarmAt(token, start + ROLE_LEASE_MS)

    expect(await holderSeenBy(laptop)).toEqual({ role: ROLE, version: 2, holder: laptop.deviceId })
    const candidates = (await roleStatus(laptop))?.candidates ?? []
    expect(candidates.find((candidate) => candidate.deviceId === desktop.deviceId)).toEqual({
      deviceId: desktop.deviceId,
      availability: "always-on",
      online: false,
      recentDrops: 1
    })
    expect(candidates.find((candidate) => candidate.deviceId === laptop.deviceId)).toMatchObject({
      online: true,
      rank: 1
    })
  })

  it("refuses a reconnected stale holder and hands the role back only after the stable window", async () => {
    const token = await signUpUser()
    const desktop = await join(token, "Desktop", "always-on")
    await holderSeenBy(desktop)
    const laptop = await join(token, "Laptop", "portable")
    await holderSeenBy(laptop)
    const start = Date.now()
    await disconnect(token, desktop.socket, "asleep")
    await runAlarmAt(token, start + ROLE_LEASE_MS)
    await holderSeenBy(laptop)

    const back = await join(token, "Desktop", "always-on", desktop.deviceId)
    const backAt = Date.now()
    expect(await holderSeenBy(back)).toEqual({ role: ROLE, version: 2, holder: laptop.deviceId })
    expect(await renew(back, 1, 7)).toMatchObject({ held: false, version: 1 })
    expect(await renew(laptop, 2, 1)).toMatchObject({ held: true })

    await holdUntil(laptop, 2, backAt + ROLE_STABLE_MS)
    await runAlarmAt(token, backAt + ROLE_STABLE_MS - 1)
    expect(await renew(laptop, 2, 2)).toMatchObject({ held: true })
    await runAlarmAt(token, backAt + ROLE_STABLE_MS)
    expect(await nextRoleFrame(laptop, "role-lease")).toMatchObject({ held: false, version: 2 })
    expect((await roleStatus(laptop))?.handingOff).toBe(true)

    laptop.socket.send(encodeCloudFrame({ t: "role-release", role: ROLE, version: 2 }))
    expect(await holderSeenBy(back)).toEqual({ role: ROLE, version: 3, holder: back.deviceId })
  })

  it("leaves the role vacant when its only candidate stops running for it", async () => {
    const token = await signUpUser()
    const desktop = await join(token, "Desktop", "always-on")
    await holderSeenBy(desktop)

    desktop.socket.send(
      encodeCloudFrame({
        t: "role-members",
        availability: "always-on",
        candidate: [],
        watch: [ROLE]
      })
    )
    expect(await holderSeenBy(desktop)).toEqual({
      role: ROLE,
      version: 1,
      holder: desktop.deviceId
    })
    desktop.socket.send(encodeCloudFrame({ t: "role-release", role: ROLE, version: 1 }))

    expect(await holderSeenBy(desktop)).toEqual({ role: ROLE, version: 1 })
  })

  it("ranks a sandbox machine as ephemeral whatever it reports", async () => {
    const token = await signUpUser()
    const sandboxId = crypto.randomUUID()
    const owner = await join(token, "Desktop", "always-on")
    await holderSeenBy(owner)
    await (
      await hubStub(token)
    ).recordMachineOrigin(sandboxId, { deviceId: owner.deviceId, name: "Desktop" }, "e2b")

    const sandbox = await join(token, "Sandbox", "always-on", sandboxId)
    await holderSeenBy(sandbox)

    const candidates = (await roleStatus(owner))?.candidates ?? []
    expect(candidates.find((candidate) => candidate.deviceId === sandboxId)).toMatchObject({
      availability: "ephemeral",
      rank: 2
    })
  })

  it("drops a removed machine from the election once its lease lapses", async () => {
    const token = await signUpUser()
    const desktop = await join(token, "Desktop", "always-on")
    await holderSeenBy(desktop)
    const laptop = await join(token, "Laptop", "portable")
    await holderSeenBy(laptop)
    const start = Date.now()

    await (await hubStub(token)).removeMachine(desktop.deviceId)
    await runAlarmAt(token, start + ROLE_LEASE_MS)

    expect(await holderSeenBy(laptop)).toEqual({ role: ROLE, version: 2, holder: laptop.deviceId })
    expect((await roleStatus(laptop))?.candidates.map((candidate) => candidate.deviceId)).toEqual([
      laptop.deviceId
    ])
  })
})
