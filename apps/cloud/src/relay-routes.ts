import { and, eq, ne } from "drizzle-orm"
import { drizzle } from "drizzle-orm/d1"
import { Hono } from "hono"

import { tunnelEndpoint } from "./db/schema.js"
import type { CloudEnv } from "./env.js"
import { isEndpointId } from "./hub-tunnel.js"

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

export const registerTunnelEndpoint = async (
  env: CloudEnv,
  registration: TunnelRegistration
): Promise<void> => {
  try {
    await storeTunnelEndpoint(env, registration)
  } catch (cause) {
    console.error("tunnel endpoint registration failed", cause)
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

export const forgetTunnelEndpoints = async (
  env: CloudEnv,
  userId: string,
  deviceId: string
): Promise<void> => {
  await drizzle(env.DB)
    .delete(tunnelEndpoint)
    .where(and(eq(tunnelEndpoint.userId, userId), eq(tunnelEndpoint.deviceId, deviceId)))
}
