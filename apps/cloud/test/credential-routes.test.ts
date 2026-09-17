import { SELF } from "cloudflare:test"
import { describe, expect, it } from "vitest"

import { BASE, authed, devLogin } from "./cloud-test-support.js"

const credential = "A".repeat(80)
const keyFor = async (token: string, deviceId?: string) => {
  const response = await SELF.fetch(`${BASE}/api/auth/api-key/create`, {
    method: "POST",
    headers: { "content-type": "application/json", ...authed(token) },
    body: JSON.stringify({
      name: "credential test",
      ...(deviceId ? { metadata: { deviceId } } : {})
    })
  })
  expect(response.status).toBe(200)
  return ((await response.json()) as { key: string }).key
}
const command = (key: string | undefined, id: string, body: object) =>
  SELF.fetch(`${BASE}/api/machine/credentials/${id}`, {
    method: "POST",
    headers: { "content-type": "application/json", ...(key ? { "x-api-key": key } : {}) },
    body: JSON.stringify(body)
  })

describe("encrypted credential coordinator API", () => {
  it("requires machine credentials and validates commands before accessing storage", async () => {
    const id = crypto.randomUUID(),
      session = await devLogin()
    const key = await keyFor(session, "device")
    expect((await command(undefined, id, { action: "read" })).status).toBe(401)
    expect((await command("invalid", id, { action: "read" })).status).toBe(401)
    expect((await command(await keyFor(session), id, { action: "read" })).status).toBe(401)
    expect((await command(key, "bad", { action: "read" })).status).toBe(400)
    expect((await command(key, id, { action: "seed", sealed: "short" })).status).toBe(400)
    expect(
      (
        await command(key, id, {
          action: "acquire",
          generation: 0,
          operationId: crypto.randomUUID()
        })
      ).status
    ).toBe(400)
    expect((await command(key, id, { action: "seed", sealed: "x".repeat(100_001) })).status).toBe(
      413
    )
  })

  it("shares one durable generation between two machines, rejects another owner's commit, and retains revocation", async () => {
    const session = await devLogin(),
      id = crypto.randomUUID()
    const a = await keyFor(session, "a"),
      b = await keyFor(session, "b"),
      operationId = crypto.randomUUID()
    const seeded = await command(a, id, { action: "seed", sealed: credential })
    expect(seeded.status).toBe(200)
    expect(seeded.headers.get("cache-control")).toBe("no-store")
    expect(seeded.headers.get("x-codevisor-account")).toBeTruthy()
    const wrongAccount = await SELF.fetch(`${BASE}/api/machine/credentials/${id}`, {
      method: "POST",
      headers: {
        "x-api-key": b,
        "x-codevisor-account": "different-user",
        "content-type": "application/json"
      },
      body: JSON.stringify({ action: "revoke" })
    })
    expect(wrongAccount.status).toBe(409)
    expect(await seeded.json()).toMatchObject({ status: "ready", credential: { generation: 1 } })
    const both = await Promise.all([
      command(a, id, { action: "acquire", generation: 1, operationId }),
      command(b, id, { action: "acquire", generation: 1, operationId })
    ])
    const states = await Promise.all(
      both.map((value) => value.json() as Promise<{ status: string }>)
    )
    expect(states.map((value) => value.status).sort()).toEqual(["acquired", "busy"])
    const owner = states[0]!.status === "acquired" ? a : b,
      other = owner === a ? b : a
    expect(await (await command(owner, id, { action: "start", operationId })).json()).toMatchObject(
      { status: "acquired" }
    )
    expect(
      await (await command(other, id, { action: "commit", operationId, sealed: credential })).json()
    ).toMatchObject({ status: "busy" })
    expect(
      await (
        await command(owner, id, { action: "commit", operationId, sealed: "B".repeat(80) })
      ).json()
    ).toMatchObject({ credential: { generation: 2 } })
    expect(await (await command(other, id, { action: "read" })).json()).toMatchObject({
      credential: { generation: 2, sealed: "B".repeat(80) }
    })
    await command(other, id, { action: "revoke" })
    expect(
      await (await command(owner, id, { action: "seed", sealed: credential })).json()
    ).toMatchObject({ status: "revoked", credential: { sealed: "" } })
  })
})
