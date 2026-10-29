import { CLOUD_PROTOCOL_VERSION } from "@codevisor/api"
import { Hono } from "hono"

import { hasAppleAuth } from "./apple-auth.js"
import { createAuth } from "./auth.js"
import { credentialRoutes, verifyMachineKey } from "./credential-routes.js"
import { hasEmailAuth } from "./email-auth.js"
import { DEV_USER, isDevAuthEnabled, type CloudEnv } from "./env.js"
import { gmailPush } from "./gmail-push.js"
import { isMachineIcon, type MachineUpdate } from "./hub-registry.js"
import { relayMap } from "./hub-tunnel.js"
import { inboxIngress } from "./inbox-ingress.js"
import { inboxRoutes } from "./inbox-routes.js"
import { userHub } from "./location-hint.js"
import { machineInviteRoutes } from "./machine-invites.js"
import { oauthClientRoutes } from "./oauth-clients.js"
import { connectAccount, nativeHandoff, nativeScheme } from "./pages/account.js"
import { loginURL, validAuthRedirect } from "./pages/auth-navigation.js"
import { loginPage } from "./pages/login.js"
import { devLoginPage, devicePage, homePage } from "./pages/pages.js"
import { pluginCatalog } from "./plugin-catalog.js"
import { pluginModeration } from "./plugin-moderation.js"
import { notifyPluginReports } from "./plugin-reports.js"
import {
  forgetTunnelEndpoints,
  registerTunnelEndpoint,
  relayRoutes,
  TUNNEL_ENDPOINT_HEADER
} from "./relay-routes.js"
import { roleRoutes } from "./role-routes.js"
import { HUB_DEVICE_ID_HEADER, HUB_KIND_HEADER, UserHub } from "./user-hub.js"
import { CLOUD_VERSION } from "./version.js"

export { UserHub }

type HonoEnv = { Bindings: CloudEnv }

const sessionUserId = async (env: CloudEnv, headers: Headers): Promise<string | undefined> => {
  const session = await createAuth(env).api.getSession({ headers })
  return session?.user.id
}

const connectionUserId = async (env: CloudEnv, request: Request): Promise<string | undefined> => {
  const token = new URL(request.url).searchParams.get("token")
  const headers = new Headers(request.headers)
  if (token !== null) headers.set("authorization", `Bearer ${token}`)
  return sessionUserId(env, headers)
}

const app = new Hono<HonoEnv>()
app.route("/", pluginModeration)
app.route("/", pluginCatalog)
app.route("/", credentialRoutes)
app.route("/", relayRoutes)
app.route("/", machineInviteRoutes)
app.route("/", inboxRoutes)
app.route("/", inboxIngress)
app.route("/", gmailPush)
app.route("/", oauthClientRoutes)
app.route("/", roleRoutes)

app.get("/.well-known/codevisor", (c) =>
  c.json({
    service: "codevisor-cloud",
    instance: c.env.INSTANCE_NAME,
    version: CLOUD_VERSION,
    protocols: [CLOUD_PROTOCOL_VERSION],
    relays: relayMap(c.env),
    authProviders: [
      ...(c.env.GITHUB_CLIENT_ID && c.env.GITHUB_CLIENT_SECRET ? ["github"] : []),
      ...(hasAppleAuth(c.env) ? ["apple"] : []),
      ...(hasEmailAuth(c.env) ? ["email"] : []),
      ...(isDevAuthEnabled(c.env) ? ["dev"] : [])
    ]
  })
)

app.get("/health", (c) => c.json({ ok: true }))

app.get("/.well-known/apple-app-site-association", (c) => {
  const { APPLE_TEAM_ID: teamId, APPLE_NATIVE_CLIENT_ID: bundleId } = c.env
  if (!teamId || !bundleId) return c.notFound()
  return c.json(
    {
      applinks: {
        details: [{ appIDs: [`${teamId}.${bundleId}`], components: [{ "/": "/device" }] }]
      }
    },
    200,
    { "cache-control": "public, max-age=3600" }
  )
})

app.on(["GET", "POST"], "/api/auth/*", (c) => createAuth(c.env).handler(c.req.raw))

app.post("/dev/login", async (c) => {
  if (!isDevAuthEnabled(c.env)) return c.notFound()
  const auth = createAuth({ ...c.env, RESEND_API_KEY: "" })
  await auth.api.signUpEmail({ body: { ...DEV_USER } }).catch(() => undefined)
  const { headers, response } = await auth.api.signInEmail({
    body: { email: DEV_USER.email, password: DEV_USER.password },
    returnHeaders: true
  })
  const token = headers.get("set-auth-token") ?? response.token
  const out = c.json({ token, user: { email: DEV_USER.email } })
  for (const cookie of headers.getSetCookie()) out.headers.append("set-cookie", cookie)
  return out
})

app.get("/login/:provider", async (c) => {
  const provider = c.req.param("provider")
  if (provider !== "github" && provider !== "apple") return c.notFound()
  const redirect = c.req.query("redirect") ?? "/auth/handoff"
  if (!validAuthRedirect(redirect)) {
    return c.json({ error: "invalid redirect" }, 400)
  }
  const scheme = nativeScheme(
    new URL(redirect, c.env.PUBLIC_BASE_URL).searchParams.get("app") ?? undefined
  )
  const errorCallbackURL = scheme
    ? `/auth/handoff?app=${scheme}&error=sign_in_failed`
    : `${loginURL(redirect)}&error=sign_in_failed`
  if (
    provider === "apple"
      ? !hasAppleAuth(c.env)
      : !c.env.GITHUB_CLIENT_ID || !c.env.GITHUB_CLIENT_SECRET
  ) {
    return c.redirect(scheme ? errorCallbackURL : `/login?redirect=${encodeURIComponent(redirect)}`)
  }
  const auth = createAuth(c.env)
  const { headers, response } = await auth.api.signInSocial({
    body: { provider, callbackURL: redirect, errorCallbackURL },
    headers: c.req.raw.headers,
    returnHeaders: true
  })
  if (response.url === undefined) {
    return c.redirect(scheme ? errorCallbackURL : `/login?redirect=${encodeURIComponent(redirect)}`)
  }
  const out = c.redirect(response.url)
  for (const cookie of headers.getSetCookie()) out.headers.append("set-cookie", cookie)
  return out
})

app.get("/auth/connect/:provider", connectAccount)
app.get("/account", nativeHandoff)
app.get("/auth/error", nativeHandoff)

app.get("/api/machines", async (c) => {
  const userId = await sessionUserId(c.env, c.req.raw.headers)
  if (userId === undefined) return c.json({ error: "unauthorized" }, 401)
  return c.json({ machines: await userHub(c.env, userId, c.req.raw.cf).listMachines() })
})

const machineName = (value: unknown): string | undefined => {
  if (typeof value !== "string") return undefined
  const name = value.trim()
  return name.length === 0 || name.length > 120 ? undefined : name
}

const parseMachineUpdate = (body: unknown): MachineUpdate | undefined => {
  if (typeof body !== "object" || body === null) return undefined
  const fields = body as { name?: unknown; icon?: unknown }
  const name = fields.name === undefined ? undefined : machineName(fields.name)
  if (fields.name !== undefined && name === undefined) return undefined
  if (fields.icon !== undefined && !isMachineIcon(fields.icon)) return undefined
  if (name === undefined && fields.icon === undefined) return undefined
  return {
    ...(name === undefined ? {} : { name }),
    ...(fields.icon === undefined ? {} : { icon: fields.icon })
  }
}

app.patch("/api/machines/:deviceId", async (c) => {
  const userId = await sessionUserId(c.env, c.req.raw.headers)
  if (userId === undefined) return c.json({ error: "unauthorized" }, 401)
  const update = parseMachineUpdate(await c.req.json<unknown>().catch(() => undefined))
  if (update === undefined) return c.json({ error: "invalid machine update" }, 400)
  const updated = await userHub(c.env, userId, c.req.raw.cf).updateMachine(
    c.req.param("deviceId"),
    update
  )
  return updated ? c.json({ ok: true }) : c.json({ error: "unknown machine" }, 404)
})

app.post("/api/machines/:deviceId/rename", async (c) => {
  const userId = await sessionUserId(c.env, c.req.raw.headers)
  if (userId === undefined) return c.json({ error: "unauthorized" }, 401)
  const body = await c.req.json<{ name?: unknown }>().catch(() => ({ name: undefined }))
  const name = machineName(body.name)
  if (name === undefined) return c.json({ error: "invalid name" }, 400)
  const renamed = await userHub(c.env, userId, c.req.raw.cf).updateMachine(
    c.req.param("deviceId"),
    {
      name
    }
  )
  return renamed ? c.json({ ok: true }) : c.json({ error: "unknown machine" }, 404)
})

const metadataDeviceId = (raw: string | null): string | undefined => {
  let value: unknown = raw
  for (let depth = 0; depth < 2 && typeof value === "string"; depth += 1) {
    try {
      value = JSON.parse(value)
    } catch {
      return undefined
    }
  }
  if (typeof value !== "object" || value === null || !("deviceId" in value)) return undefined
  return typeof value.deviceId === "string" ? value.deviceId : undefined
}

const removeMachine = async (
  env: CloudEnv,
  userId: string,
  deviceId: string,
  cf: unknown
): Promise<boolean> => {
  const { results } = await userApiKeys(env, userId)
  const revoked = results.filter((row) => metadataDeviceId(row.metadata) === deviceId)
  if (revoked.length > 0) {
    await env.DB.batch(revoked.map((row) => env.DB.prepare(apiKeySql.delete).bind(row.id)))
  }
  await forgetTunnelEndpoints(env, userId, deviceId)
  return userHub(env, userId, cf).removeMachine(deviceId)
}

app.delete("/api/machines/:deviceId", async (c) => {
  const userId = await sessionUserId(c.env, c.req.raw.headers)
  if (userId === undefined) return c.json({ error: "unauthorized" }, 401)
  const removed = await removeMachine(c.env, userId, c.req.param("deviceId"), c.req.raw.cf)
  return removed ? c.json({ ok: true }) : c.json({ error: "unknown machine" }, 404)
})

app.delete("/api/machine/self", async (c) => {
  const machine = await verifyMachineKey(c.env, c.req.header("x-api-key"))
  if (machine === undefined) return c.json({ error: "invalid machine credential" }, 401)
  await removeMachine(c.env, machine.userId, machine.deviceId, c.req.raw.cf)
  return c.json({ ok: true })
})

app.delete("/api/machine/peers/:deviceId", async (c) => {
  const machine = await verifyMachineKey(c.env, c.req.header("x-api-key"))
  if (machine === undefined) return c.json({ error: "invalid machine credential" }, 401)
  const target = c.req.param("deviceId")
  if (target === machine.deviceId) {
    return c.json({ error: "use DELETE /api/machine/self to remove this machine" }, 400)
  }
  const removed = await removeMachine(c.env, machine.userId, target, c.req.raw.cf)
  return removed ? c.json({ ok: true }) : c.json({ error: "unknown machine" }, 404)
})

app.get("/api/machine/credential", async (c) => {
  const key = c.req.header("x-api-key")
  if (key === undefined) return c.json({ error: "missing x-api-key" }, 401)
  const verified = await createAuth(c.env).api.verifyApiKey({ body: { key } })
  return verified.valid ? c.json({ ok: true }) : c.json({ error: "invalid credential" }, 401)
})

app.get("/connect", async (c) => {
  if (c.req.header("Upgrade")?.toLowerCase() !== "websocket") {
    return c.json({ error: "websocket upgrade required" }, 426)
  }
  const machineKey = c.req.header("x-api-key") ?? c.req.query("apiKey")
  const headers = new Headers(c.req.raw.headers)
  let userId: string
  let deviceId: string
  if (machineKey !== undefined) {
    const auth = createAuth(c.env)
    const verified = await auth.api.verifyApiKey({ body: { key: machineKey } })
    const metadata = verified.key?.metadata as { deviceId?: string } | null | undefined
    if (!verified.valid || verified.key === null || typeof metadata?.deviceId !== "string") {
      return c.json({ error: "invalid machine credential" }, 401)
    }
    userId = verified.key.referenceId
    headers.set(HUB_KIND_HEADER, "machine")
    headers.set(HUB_DEVICE_ID_HEADER, metadata.deviceId)
    deviceId = metadata.deviceId
  } else {
    const sessionUser = await connectionUserId(c.env, c.req.raw)
    if (sessionUser === undefined) return c.json({ error: "unauthorized" }, 401)
    userId = sessionUser
    headers.set(HUB_KIND_HEADER, "app")
    deviceId = `app:${c.req.header(TUNNEL_ENDPOINT_HEADER) ?? ""}`
  }
  await registerTunnelEndpoint(c.env, {
    endpointId: c.req.header(TUNNEL_ENDPOINT_HEADER),
    userId,
    deviceId,
    kind: headers.get(HUB_KIND_HEADER)!
  })
  return userHub(c.env, userId, c.req.raw.cf).fetch(new Request(c.req.raw.url, { headers }))
})

app.get("/", (c) => homePage(c))
app.get("/login", (c) => loginPage(c))
app.get("/dev-login", (c) => devLoginPage(c))
app.get("/device", async (c) => devicePage(c))
app.get("/auth/handoff", nativeHandoff)

const worker = {
  fetch: app.fetch,
  scheduled: (_controller: ScheduledController, env: CloudEnv, ctx: ExecutionContext): void => {
    ctx.waitUntil(notifyPluginReports(env))
  }
} satisfies ExportedHandler<CloudEnv>

export default worker

const userApiKeys = (env: CloudEnv, userId: string) =>
  env.DB.prepare(apiKeySql.byUser).bind(userId).all<{ id: string; metadata: string | null }>()

const apiKeySql = {
  byUser: "SELECT id, metadata FROM apikey WHERE reference_id = ?",
  delete: "DELETE FROM apikey WHERE id = ?"
}
