import { createHmac, randomBytes } from "node:crypto"

/// Pane traffic cannot carry the machine bearer token: WKWebView cannot set
/// Authorization on subresource loads and the cloud relay strips the header.
/// Instead the client exchanges an authorized POST for a short-lived pane
/// token, the initial navigation carries it in the query, and the proxy
/// swaps it for a scoped HttpOnly cookie that covers every subsequent
/// subresource/fetch/WS request.
export const PANE_TOKEN_QUERY_PARAM = "codevisorPaneToken"

/// Initial tokens are only meant to survive the gap between token issue and
/// the webview's first navigation.
const INITIAL_TOKEN_TTL_MS = 10 * 60_000

/// Once the navigation exchange succeeds the token backs a cookie session;
/// panes stay open for hours, and every proxied request slides the window.
const SESSION_TTL_MS = 12 * 60 * 60_000

export interface PaneTokenScope {
  readonly pluginId: string
  readonly paneId: string
  readonly paneType: string
  readonly workspaceId?: string | undefined
  readonly cwd?: string | undefined
  readonly themeMode?: string | undefined
}

interface PaneTokenRecord {
  readonly scope: PaneTokenScope
  expiresAt: number
}

export interface PaneTokenStore {
  readonly issue: (scope: PaneTokenScope) => { readonly token: string; readonly expiresAt: string }
  /// Returns the scope when the token is live and belongs to the plugin;
  /// slides the expiry window on every hit so active panes never expire.
  readonly verify: (token: string, pluginId: string) => PaneTokenScope | undefined
  /// Promotes an initial token to a long-lived cookie session (called when
  /// the navigation exchange sets the cookie).
  readonly establishSession: (token: string) => void
  /// Signs a serialized context payload so plugins can trust
  /// X-Codevisor-Context came from this server, not another local process.
  readonly signContext: (payload: string) => string
}

export const makePaneTokenStore = (now: () => number = Date.now): PaneTokenStore => {
  const records = new Map<string, PaneTokenRecord>()
  const secret = randomBytes(32)
  const sweep = (): void => {
    const current = now()
    for (const [token, record] of records) {
      if (record.expiresAt <= current) {
        records.delete(token)
      }
    }
  }
  return {
    establishSession: (token) => {
      const record = records.get(token)
      if (record !== undefined) {
        record.expiresAt = now() + SESSION_TTL_MS
      }
    },
    issue: (scope) => {
      sweep()
      const token = randomBytes(24).toString("base64url")
      const expiresAt = now() + INITIAL_TOKEN_TTL_MS
      records.set(token, { expiresAt, scope })
      return { expiresAt: new Date(expiresAt).toISOString(), token }
    },
    signContext: (payload) => createHmac("sha256", secret).update(payload).digest("hex"),
    verify: (token, pluginId) => {
      const record = records.get(token)
      if (record === undefined || record.scope.pluginId !== pluginId) {
        return undefined
      }
      if (record.expiresAt <= now()) {
        records.delete(token)
        return undefined
      }
      record.expiresAt = Math.max(record.expiresAt, now() + INITIAL_TOKEN_TTL_MS)
      return record.scope
    }
  }
}

/// Cookie names cannot safely carry the id's namespace dot everywhere, so it
/// is flattened; the cookie is additionally path-scoped to the plugin's proxy
/// prefix so plugins can never read each other's sessions.
export const paneCookieName = (pluginId: string): string =>
  `codevisor-plugin-${pluginId.replace(/[^a-z0-9-]/g, "-")}`

export const paneCookieHeader = (pluginId: string, token: string): string =>
  `${paneCookieName(pluginId)}=${token}; Path=/v1/plugins/${pluginId}/; HttpOnly; SameSite=Lax`

export const readCookieValue = (
  header: string | undefined,
  cookieName: string
): string | undefined => {
  if (header === undefined) {
    return undefined
  }
  for (const part of header.split(";")) {
    const separator = part.indexOf("=")
    if (separator === -1) {
      continue
    }
    if (part.slice(0, separator).trim() === cookieName) {
      return part.slice(separator + 1).trim()
    }
  }
  return undefined
}

/// Strips our pane-session cookie from a forwarded Cookie header: it is proxy
/// auth, not plugin state, and forwarding it would leak session tokens into
/// arbitrary plugin processes.
export const stripPaneCookie = (
  header: string | undefined,
  cookieName: string
): string | undefined => {
  if (header === undefined) {
    return undefined
  }
  const kept = header
    .split(";")
    .map((part) => part.trim())
    .filter((part) => part.length > 0 && !part.startsWith(`${cookieName}=`))
  return kept.length === 0 ? undefined : kept.join("; ")
}
