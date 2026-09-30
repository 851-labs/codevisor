import type { CloudMachinePresence } from "@codevisor/api"
import { generateDeviceKeyPair } from "@codevisor/cloud-crypto"
import { env, SELF } from "cloudflare:test"
import { describe, expect, it, vi } from "vitest"

import { authed, BASE, connectMachine, devLogin } from "./cloud-test-support.js"

const mintInvite = (apiKey: string) =>
  SELF.fetch(`${BASE}/api/machine/invites`, { method: "POST", headers: { "x-api-key": apiKey } })

const redeem = (token: string, name = "hetzner-1", deviceId = crypto.randomUUID()) =>
  SELF.fetch(`${BASE}/api/machine/invites/redeem`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      token,
      name,
      deviceId,
      publicKey: generateDeviceKeyPair().publicKey
    })
  })

const inviteToken = async (apiKey: string): Promise<string> => {
  const response = await mintInvite(apiKey)
  expect(response.status).toBe(200)
  return ((await response.json()) as { token: string }).token
}

const machines = async (session: string): Promise<CloudMachinePresence[]> => {
  const response = await SELF.fetch(`${BASE}/api/machines`, { headers: authed(session) })
  return ((await response.json()) as { machines: CloudMachinePresence[] }).machines
}

describe("machine invites", () => {
  it("lets a machine add a new machine that joins with its own credential", async () => {
    const session = await devLogin()
    const inviter = await connectMachine(session, "mac-studio")
    const token = await inviteToken(inviter.apiKey)

    const deviceId = crypto.randomUUID()
    const redeemed = await redeem(token, "hetzner-1", deviceId)
    expect(redeemed.status).toBe(200)
    const { key } = (await redeemed.json()) as { key: string }
    expect(key).not.toBe(inviter.apiKey)

    // The new machine connects with its own key and is labeled with its inviter.
    const joined = await connectMachine(session, "hetzner-1", deviceId, { apiKey: key })
    expect(joined.welcome.t).toBe("welcome")
    const listed = await machines(session)
    expect(listed.find((m) => m.deviceId === deviceId)?.addedBy).toEqual({
      deviceId: inviter.deviceId,
      name: "mac-studio"
    })
    expect(listed.find((m) => m.deviceId === inviter.deviceId)?.addedBy).toBeUndefined()
  })

  it("refuses reused, expired, and bogus invites", async () => {
    const session = await devLogin()
    const inviter = await connectMachine(session, "mac-studio")
    const token = await inviteToken(inviter.apiKey)
    expect((await redeem(token)).status).toBe(200)
    expect((await redeem(token)).status).toBe(401)
    expect((await redeem("x".repeat(43))).status).toBe(401)

    const stale = await inviteToken(inviter.apiKey)
    vi.setSystemTime(Date.now() + 11 * 60 * 1000)
    expect((await redeem(stale)).status).toBe(401)
  })

  it("requires a machine credential to mint, and validates redemptions", async () => {
    const session = await devLogin()
    expect((await mintInvite("not-a-key")).status).toBe(401)
    const byUser = await SELF.fetch(`${BASE}/api/machine/invites`, {
      method: "POST",
      headers: authed(session)
    })
    expect(byUser.status).toBe(401)
    const inviter = await connectMachine(session, "mac-studio")
    const token = await inviteToken(inviter.apiKey)
    expect((await redeem(token, "hetzner-1", "not-a-uuid")).status).toBe(400)
    // A malformed request never burns the invite.
    expect((await redeem(token)).status).toBe(200)
  })

  it("voids invites when the inviting machine is removed", async () => {
    const session = await devLogin()
    const inviter = await connectMachine(session, "mac-studio")
    const token = await inviteToken(inviter.apiKey)
    const removed = await SELF.fetch(`${BASE}/api/machines/${inviter.deviceId}`, {
      method: "DELETE",
      headers: authed(session)
    })
    expect(removed.status).toBe(200)
    expect((await redeem(token)).status).toBe(401)
  })

  it("mints as many invites as asked, keeping only live ones", async () => {
    const session = await devLogin()
    const inviter = await connectMachine(session, "mac-studio")
    const invites = (): Promise<number> =>
      env.DB.prepare("SELECT COUNT(*) AS count FROM machine_invite")
        .first<{ count: number }>()
        .then((row) => row?.count ?? 0)
    for (let index = 0; index < 25; index += 1) await inviteToken(inviter.apiKey)
    expect(await invites()).toBeGreaterThanOrEqual(25)

    // Once they've expired, the next invite clears them out.
    vi.setSystemTime(Date.now() + 11 * 60 * 1000)
    const live = await inviteToken(inviter.apiKey)
    expect(await invites()).toBe(1)
    expect((await redeem(live)).status).toBe(200)
  })
})

describe("machine peer removal", () => {
  it("lets a machine remove another machine on its account, not itself", async () => {
    const session = await devLogin()
    const remover = await connectMachine(session, "mac-studio")
    const target = await connectMachine(session, "hetzner-1")
    const remove = (deviceId: string, apiKey = remover.apiKey) =>
      SELF.fetch(`${BASE}/api/machine/peers/${deviceId}`, {
        method: "DELETE",
        headers: { "x-api-key": apiKey }
      })
    expect((await remove(target.deviceId, "not-a-key")).status).toBe(401)
    expect((await remove(remover.deviceId)).status).toBe(400)
    expect((await remove(target.deviceId)).status).toBe(200)
    expect((await machines(session)).map((m) => m.deviceId)).not.toContain(target.deviceId)
    expect((await remove(target.deviceId)).status).toBe(404)
  })
})
