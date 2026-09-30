import { Hono } from "hono"
import { bodyLimit } from "hono/body-limit"

import { createAuth } from "./auth.js"
import { verifyMachineKey } from "./credential-routes.js"
import type { CloudEnv } from "./env.js"
import { hubLocationHint } from "./location-hint.js"
import type { UserHub } from "./user-hub.js"

/// Machine-to-machine enrollment: a machine already on an account mints a
/// one-time invite (`codevisor machines invite`), and a new machine redeems
/// it for its own long-lived credential — no human approval in between.
///
/// This grants nothing a machine can't already do: every machine on an
/// account can run tools and agents on every other one. The new machine gets
/// its own credential (never a copy of the inviter's), is recorded as added
/// by the inviting machine, and can be removed on its own.

export const machineInviteRoutes = new Hono<{ Bindings: CloudEnv }>()

export const INVITE_TTL_MS = 10 * 60 * 1000

const hub = (env: CloudEnv, userId: string, cf: unknown): DurableObjectStub<UserHub> => {
  const locationHint = hubLocationHint(cf)
  return (env.USER_HUB as unknown as DurableObjectNamespace<UserHub>).getByName(
    userId,
    locationHint === undefined ? undefined : { locationHint }
  )
}

const base64url = (bytes: Uint8Array): string =>
  btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "")

const sha256Hex = async (value: string): Promise<string> => {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("")
}

/// Whether a device still holds a credential on the account. An invite dies
/// with the machine that minted it.
const deviceHasCredential = async (
  env: CloudEnv,
  userId: string,
  deviceId: string
): Promise<boolean> => {
  const { results } = await env.DB.prepare("SELECT metadata FROM apikey WHERE reference_id = ?")
    .bind(userId)
    .all<{ metadata: string | null }>()
  return results.some((row) => {
    let value: unknown = row.metadata
    for (let depth = 0; depth < 2 && typeof value === "string"; depth += 1) {
      try {
        value = JSON.parse(value)
      } catch {
        return false
      }
    }
    return (value as { deviceId?: unknown } | null)?.deviceId === deviceId
  })
}

/// Mint an invite, authenticated by the inviting machine's own api key.
/// Answers the raw secret once; only its hash is stored.
machineInviteRoutes.post("/api/machine/invites", async (c) => {
  const machine = await verifyMachineKey(c.env, c.req.header("x-api-key"))
  if (machine === undefined) return c.json({ error: "invalid machine credential" }, 401)
  const now = Date.now()
  const machines = await hub(c.env, machine.userId, c.req.raw.cf).listMachines()
  const inviterName =
    machines.find((entry) => entry.deviceId === machine.deviceId)?.name ?? "another machine"
  const token = base64url(crypto.getRandomValues(new Uint8Array(32)))
  const expiresAt = now + INVITE_TTL_MS
  await c.env.DB.batch([
    // Expired invites (used or not) are never read again; drop the account's
    // old ones here so the table only holds live invites.
    c.env.DB.prepare("DELETE FROM machine_invite WHERE user_id = ? AND expires_at <= ?").bind(
      machine.userId,
      now
    ),
    c.env.DB.prepare(
      `INSERT INTO machine_invite
         (token_hash, user_id, created_by_device_id, created_by_name, created_at, expires_at)
       VALUES (?, ?, ?, ?, ?, ?)`
    ).bind(await sha256Hex(token), machine.userId, machine.deviceId, inviterName, now, expiresAt)
  ])
  c.header("Cache-Control", "no-store")
  return c.json({ token, expiresAt: new Date(expiresAt).toISOString() })
})

interface RedeemBody {
  readonly token?: unknown
  readonly name?: unknown
  readonly deviceId?: unknown
  readonly publicKey?: unknown
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/// Redeem an invite: the new machine sends the secret plus its freshly
/// generated device id and public key, and receives its own api key. The
/// secret key never leaves the new machine.
machineInviteRoutes.post(
  "/api/machine/invites/redeem",
  bodyLimit({ maxSize: 8_192 }),
  async (c) => {
    const body = (await c.req.json<RedeemBody>().catch(() => ({}))) as RedeemBody
    if (
      typeof body.token !== "string" ||
      body.token.length < 20 ||
      body.token.length > 200 ||
      typeof body.deviceId !== "string" ||
      !UUID.test(body.deviceId) ||
      typeof body.publicKey !== "string" ||
      body.publicKey.length < 20 ||
      body.publicKey.length > 200 ||
      typeof body.name !== "string" ||
      body.name.trim().length === 0 ||
      body.name.length > 120
    ) {
      return c.json({ error: "invalid invite redemption" }, 400)
    }
    const now = Date.now()
    // One conditional write claims the invite: a replayed or concurrent
    // redemption finds nothing left to claim.
    const invite = await c.env.DB.prepare(
      `UPDATE machine_invite SET redeemed_at = ?, redeemed_device_id = ?
       WHERE token_hash = ? AND redeemed_at IS NULL AND expires_at > ?
       RETURNING user_id, created_by_device_id, created_by_name`
    )
      .bind(now, body.deviceId, await sha256Hex(body.token), now)
      .first<{ user_id: string; created_by_device_id: string; created_by_name: string }>()
    if (invite === null) {
      return c.json({ error: "This invite is invalid, expired, or already used." }, 401)
    }
    if (!(await deviceHasCredential(c.env, invite.user_id, invite.created_by_device_id))) {
      return c.json({ error: "This invite is no longer valid." }, 401)
    }
    const name = body.name.trim()
    const created = await createAuth(c.env).api.createApiKey({
      body: {
        userId: invite.user_id,
        // Credential labels have a 32-character limit (see provisionMachine).
        name: name.slice(0, 32),
        metadata: { deviceId: body.deviceId, publicKey: body.publicKey }
      }
    })
    await hub(c.env, invite.user_id, c.req.raw.cf).recordMachineOrigin(body.deviceId, {
      deviceId: invite.created_by_device_id,
      name: invite.created_by_name
    })
    c.header("Cache-Control", "no-store")
    return c.json({ key: created.key })
  }
)
