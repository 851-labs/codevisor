import { and, eq, ne } from "drizzle-orm"
import { drizzle } from "drizzle-orm/d1"
import { Hono } from "hono"

import { tunnelEndpoint } from "./db/schema.js"
import type { CloudEnv } from "./env.js"
import { isEndpointId, tunnelRolloutMode } from "./hub-tunnel.js"

/// Tunnel relay access control (docs/plans/codevisor-tunnel.md). Our relays
/// run iroh-relay with `access.http`: for every client they POST here with
/// the client's hex endpoint id, and admit it only on `200 true`. The pinned
/// v1.2.0 binary names the header `X-Iroh-NodeId` (observed on the wire);
/// iroh's source docs call it `X-Iroh-Endpoint-Id` — accept both. Endpoints are
/// registered by authenticated devices on `/connect` (registerTunnelEndpoint).

export const TUNNEL_ENDPOINT_HEADER = "x-codevisor-tunnel-endpoint"

const bearerTokens = (env: CloudEnv): string[] =>
  (env.RELAY_AUTHORIZE_TOKEN ?? "")
    .split(",")
    .map((token) => token.trim())
    .filter((token) => token.length > 0)

export const relayRoutes = new Hono<{ Bindings: CloudEnv }>()

relayRoutes.post("/api/relay/authorize", async (c) => {
  const tokens = bearerTokens(c.env)
  if (tokens.length === 0) return c.notFound()
  const presented = c.req.header("authorization")?.replace(/^Bearer /, "")
  if (presented === undefined || !tokens.includes(presented)) {
    return c.text("false", 401)
  }
  const endpointId = (
    c.req.header("x-iroh-nodeid") ?? c.req.header("x-iroh-endpoint-id")
  )?.toLowerCase()
  if (!isEndpointId(endpointId)) return c.text("false", 403)
  const row = await drizzle(c.env.DB)
    .select({ endpointId: tunnelEndpoint.endpointId })
    .from(tunnelEndpoint)
    .where(eq(tunnelEndpoint.endpointId, endpointId))
    .get()
  return row === undefined ? c.text("false", 403) : c.text("true")
})

/// Called by `/connect` after authentication: records that this account owns
/// the endpoint id the device presented, so our relays will serve it. A
/// device re-keying replaces its previous endpoint. Best effort: relay access
/// only matters to tunnel devices, so a D1 failure here is logged and never
/// costs a device its hub connection.
export const registerTunnelEndpoint = async (
  env: CloudEnv,
  registration: TunnelRegistration,
  log: (message: string, cause: unknown) => void = console.error
): Promise<void> => {
  try {
    await storeTunnelEndpoint(env, registration)
  } catch (cause) {
    log("tunnel endpoint registration failed", cause)
  }
}

interface TunnelRegistration {
  readonly endpointId: string | undefined
  readonly userId: string
  readonly deviceId: string
  readonly kind: string
}

const storeTunnelEndpoint = async (
  env: CloudEnv,
  registration: TunnelRegistration
): Promise<void> => {
  // While the tunnel is off for everyone, /connect stays exactly as it was.
  if (tunnelRolloutMode(env) === "off") return
  const endpointId = registration.endpointId?.toLowerCase()
  if (!isEndpointId(endpointId)) return
  const db = drizzle(env.DB)
  await db
    .delete(tunnelEndpoint)
    .where(
      and(
        eq(tunnelEndpoint.userId, registration.userId),
        eq(tunnelEndpoint.deviceId, registration.deviceId),
        ne(tunnelEndpoint.endpointId, endpointId)
      )
    )
  await db
    .insert(tunnelEndpoint)
    .values({
      endpointId,
      userId: registration.userId,
      deviceId: registration.deviceId,
      kind: registration.kind,
      updatedAt: Date.now()
    })
    .onConflictDoUpdate({
      target: tunnelEndpoint.endpointId,
      set: {
        userId: registration.userId,
        deviceId: registration.deviceId,
        kind: registration.kind,
        updatedAt: Date.now()
      }
    })
}

/// Machine removal: its endpoint must stop being able to use our relays.
export const forgetTunnelEndpoints = async (
  env: CloudEnv,
  userId: string,
  deviceId: string
): Promise<void> => {
  await drizzle(env.DB)
    .delete(tunnelEndpoint)
    .where(and(eq(tunnelEndpoint.userId, userId), eq(tunnelEndpoint.deviceId, deviceId)))
}
