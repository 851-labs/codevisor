import { CLOUD_PROTOCOL_VERSION } from "@codevisor/api"
import { Hono } from "hono"
import { createAuth } from "./auth.js"
import { DEV_USER, isDevAuthEnabled, type CloudEnv } from "./env.js"
import { devLoginPage, devicePage, handoffPage, homePage, loginPage } from "./pages/pages.js"
import { HUB_DEVICE_ID_HEADER, HUB_KIND_HEADER, UserHub } from "./user-hub.js"
import { CLOUD_VERSION } from "./version.js"

// Note: the Worker entry module may only export handlers/DO classes — plain
// value re-exports (strings, constants) crash workerd at startup.
export { UserHub }

type HonoEnv = { Bindings: CloudEnv }

const hub = (env: CloudEnv, userId: string): DurableObjectStub<UserHub> =>
  (env.USER_HUB as unknown as DurableObjectNamespace<UserHub>).getByName(userId)

const sessionUserId = async (env: CloudEnv, headers: Headers): Promise<string | undefined> => {
  const session = await createAuth(env).api.getSession({ headers })
  return session?.user.id
}

/// Session lookup that also honours `?token=` — WebSocket clients that cannot
/// set request headers (browsers) put their bearer token in the query string.
const connectionUserId = async (env: CloudEnv, request: Request): Promise<string | undefined> => {
  const token = new URL(request.url).searchParams.get("token")
  const headers = new Headers(request.headers)
  if (token !== null) headers.set("authorization", `Bearer ${token}`)
  return sessionUserId(env, headers)
}

const app = new Hono<HonoEnv>()

// -- Discovery & liveness ----------------------------------------------------

app.get("/.well-known/codevisor", (c) =>
  c.json({
    service: "codevisor-cloud",
    instance: c.env.INSTANCE_NAME,
    version: CLOUD_VERSION,
    protocols: [CLOUD_PROTOCOL_VERSION],
    authProviders: [
      ...(c.env.GITHUB_CLIENT_ID !== undefined ? ["github"] : []),
      ...(isDevAuthEnabled(c.env) ? ["dev"] : [])
    ]
  })
)

app.get("/health", (c) => c.json({ ok: true }))

// -- Auth --------------------------------------------------------------------

app.on(["GET", "POST"], "/api/auth/*", (c) => createAuth(c.env).handler(c.req.raw))

/// Dev-only credential login. Creates the fixed dev user on first use and
/// returns a bearer token (native/CLI path) while also setting the session
/// cookie (browser path, so /device approval works in dev).
app.post("/dev/login", async (c) => {
  if (!isDevAuthEnabled(c.env)) return c.notFound()
  const auth = createAuth(c.env)
  await auth.api.signUpEmail({ body: { ...DEV_USER } }).catch(() => undefined) // already exists
  const { headers, response } = await auth.api.signInEmail({
    body: { email: DEV_USER.email, password: DEV_USER.password },
    returnHeaders: true
  })
  const token = headers.get("set-auth-token") ?? response.token
  const out = c.json({ token, user: { email: DEV_USER.email } })
  for (const cookie of headers.getSetCookie()) out.headers.append("set-cookie", cookie)
  return out
})

/// One-click GitHub sign-in for native apps: starts the social flow
/// server-side and 302s straight to GitHub's consent page — no interstitial.
/// Must be a server redirect (not an app-side POST) because Better Auth's
/// PKCE/state cookies have to land in the browser session that will hit the
/// OAuth callback. Falls back to the /login page when GitHub isn't configured.
app.get("/login/github", async (c) => {
  const redirect = c.req.query("redirect") ?? "/auth/handoff"
  // Relative paths only: this must never become an open redirect.
  if (!redirect.startsWith("/") || redirect.startsWith("//")) {
    return c.json({ error: "invalid redirect" }, 400)
  }
  if (c.env.GITHUB_CLIENT_ID === undefined) {
    return c.redirect(`/login?redirect=${encodeURIComponent(redirect)}`)
  }
  const auth = createAuth(c.env)
  const { headers, response } = await auth.api.signInSocial({
    body: { provider: "github", callbackURL: redirect },
    headers: c.req.raw.headers,
    returnHeaders: true
  })
  if (response.url === undefined) {
    return c.redirect(`/login?redirect=${encodeURIComponent(redirect)}`)
  }
  const out = c.redirect(response.url)
  // Carry Better Auth's state/PKCE cookies into the browser session.
  for (const cookie of headers.getSetCookie()) out.headers.append("set-cookie", cookie)
  return out
})

// -- Machine registry (session-authenticated REST for apps) -------------------

app.get("/api/machines", async (c) => {
  const userId = await sessionUserId(c.env, c.req.raw.headers)
  if (userId === undefined) return c.json({ error: "unauthorized" }, 401)
  return c.json({ machines: await hub(c.env, userId).listMachines() })
})

app.post("/api/machines/:deviceId/rename", async (c) => {
  const userId = await sessionUserId(c.env, c.req.raw.headers)
  if (userId === undefined) return c.json({ error: "unauthorized" }, 401)
  const body = await c.req.json<{ name?: string }>().catch(() => ({ name: undefined }))
  const name = body.name?.trim()
  if (name === undefined || name.length === 0 || name.length > 120) {
    return c.json({ error: "invalid name" }, 400)
  }
  const renamed = await hub(c.env, userId).renameMachine(c.req.param("deviceId"), name)
  return renamed ? c.json({ ok: true }) : c.json({ error: "unknown machine" }, 404)
})

/// Disconnect a machine from the account: revoke its api key (auth-side) and
/// drop + forget it on the hub (connection-side).
app.delete("/api/machines/:deviceId", async (c) => {
  const auth = createAuth(c.env)
  const session = await auth.api.getSession({ headers: c.req.raw.headers })
  if (session === null) return c.json({ error: "unauthorized" }, 401)
  const deviceId = c.req.param("deviceId")
  const { apiKeys } = await auth.api.listApiKeys({ headers: c.req.raw.headers })
  for (const key of apiKeys) {
    const metadata = key.metadata as { deviceId?: string } | null
    if (metadata?.deviceId === deviceId) {
      await auth.api.deleteApiKey({ body: { keyId: key.id }, headers: c.req.raw.headers })
    }
  }
  const removed = await hub(c.env, session.user.id).removeMachine(deviceId)
  return removed ? c.json({ ok: true }) : c.json({ error: "unknown machine" }, 404)
})

/// Cheap machine-credential probe: lets a machine confirm its stored api key
/// is still valid without a WebSocket round trip (used by dev environments to
/// self-heal after a local cloud reset, and handy for diagnostics anywhere).
app.get("/api/machine/credential", async (c) => {
  const key = c.req.header("x-api-key")
  if (key === undefined) return c.json({ error: "missing x-api-key" }, 401)
  const verified = await createAuth(c.env).api.verifyApiKey({ body: { key } })
  return verified.valid ? c.json({ ok: true }) : c.json({ error: "invalid credential" }, 401)
})

// -- Relay connection ---------------------------------------------------------

app.get("/connect", async (c) => {
  if (c.req.header("Upgrade")?.toLowerCase() !== "websocket") {
    return c.json({ error: "websocket upgrade required" }, 426)
  }
  const machineKey = c.req.header("x-api-key") ?? c.req.query("apiKey")
  const headers = new Headers(c.req.raw.headers)
  let userId: string
  if (machineKey !== undefined) {
    const auth = createAuth(c.env)
    const verified = await auth.api.verifyApiKey({ body: { key: machineKey } })
    const metadata = verified.key?.metadata as { deviceId?: string } | null | undefined
    if (!verified.valid || verified.key === null || typeof metadata?.deviceId !== "string") {
      return c.json({ error: "invalid machine credential" }, 401)
    }
    // references: "user" (the default), so referenceId is the owning user id.
    userId = verified.key.referenceId
    headers.set(HUB_KIND_HEADER, "machine")
    headers.set(HUB_DEVICE_ID_HEADER, metadata.deviceId)
  } else {
    const sessionUser = await connectionUserId(c.env, c.req.raw)
    if (sessionUser === undefined) return c.json({ error: "unauthorized" }, 401)
    userId = sessionUser
    headers.set(HUB_KIND_HEADER, "app")
  }
  return hub(c.env, userId).fetch(new Request(c.req.raw.url, { headers }))
})

// -- Pages (the only human-facing HTML in the system) -------------------------

app.get("/", (c) => homePage(c))
app.get("/login", (c) => loginPage(c))
app.get("/dev-login", (c) => devLoginPage(c))
app.get("/device", async (c) => devicePage(c))
app.get("/auth/handoff", async (c) => handoffPage(c))

export default app
