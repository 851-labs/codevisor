import { createHmac, randomBytes } from "node:crypto"
import type { IncomingMessage } from "node:http"

import type { PluginPaneTokenRequest, PluginPaneTokenResponse } from "@codevisor/api"

import type { InstalledPlugin } from "./plugin-store.js"
import { PluginsError } from "./plugins-error.js"

export const PANE_TOKEN_QUERY_PARAM = "codevisorPaneToken"

const INITIAL_TOKEN_TTL_MS = 10 * 60_000

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
  readonly verify: (token: string, pluginId: string) => PaneTokenScope | undefined
  readonly exchange: (token: string, pluginId: string) => PaneTokenScope | undefined
  readonly contextSecret: (pluginId: string) => string
  readonly signContext: (pluginId: string, payload: string) => string
}

export const makePaneTokenStore = (now: () => number = Date.now): PaneTokenStore => {
  const records = new Map<string, PaneTokenRecord>()
  const secret = randomBytes(32)
  const contextSecret = (pluginId: string): string =>
    createHmac("sha256", secret).update(`codevisor-plugin-context:${pluginId}`).digest("hex")
  const sweep = (): void => {
    const current = now()
    for (const [token, record] of records) {
      if (record.expiresAt <= current) {
        records.delete(token)
      }
    }
  }
  const extend = (token: string, pluginId: string, ttlMs: number): PaneTokenScope | undefined => {
    const record = records.get(token)
    if (record === undefined || record.scope.pluginId !== pluginId) {
      return undefined
    }
    if (record.expiresAt <= now()) {
      records.delete(token)
      return undefined
    }
    record.expiresAt = Math.max(record.expiresAt, now() + ttlMs)
    return record.scope
  }
  return {
    contextSecret,
    exchange: (token, pluginId) => extend(token, pluginId, SESSION_TTL_MS),
    issue: (scope) => {
      sweep()
      const token = randomBytes(24).toString("base64url")
      const expiresAt = now() + INITIAL_TOKEN_TTL_MS
      records.set(token, { expiresAt, scope })
      return { expiresAt: new Date(expiresAt).toISOString(), token }
    },
    signContext: (pluginId, payload) =>
      createHmac("sha256", contextSecret(pluginId)).update(payload).digest("hex"),
    verify: (token, pluginId) => extend(token, pluginId, INITIAL_TOKEN_TTL_MS)
  }
}

export const makeSignedContextHeaders =
  (tokens: PaneTokenStore) =>
  (pluginId: string) =>
  (payload: Readonly<Record<string, unknown>>): Record<string, string> => {
    const encoded = Buffer.from(JSON.stringify(payload), "utf8").toString("base64")
    return {
      "x-codevisor-context": encoded,
      "x-codevisor-context-signature": tokens.signContext(pluginId, encoded)
    }
  }

export const makePaneContextHeaders =
  (signedContextHeaders: ReturnType<typeof makeSignedContextHeaders>) =>
  (scope: PaneTokenScope): Record<string, string> =>
    signedContextHeaders(scope.pluginId)({
      cwd: scope.cwd,
      paneId: scope.paneId,
      paneType: scope.paneType,
      pluginId: scope.pluginId,
      themeMode: scope.themeMode,
      workspaceId: scope.workspaceId
    })

type AuthenticatedPane = { scope: PaneTokenScope; viaQueryToken: boolean }

const exchangePaneQueryToken = (
  tokens: PaneTokenStore,
  queryToken: string,
  pluginId: string
): AuthenticatedPane | undefined => {
  const scope = tokens.exchange(queryToken, pluginId)
  if (scope !== undefined) {
    return { scope, viaQueryToken: true }
  }
  return undefined
}

const verifyPaneCookie = (
  tokens: PaneTokenStore,
  pluginId: string,
  request: IncomingMessage
): AuthenticatedPane | undefined => {
  const cookieToken = readCookieValue(request.headers.cookie, paneCookieName(pluginId))
  if (cookieToken !== undefined) {
    const scope = tokens.verify(cookieToken, pluginId)
    if (scope !== undefined) {
      return { scope, viaQueryToken: false }
    }
  }
  return undefined
}

export const makePaneAuthenticator =
  (tokens: PaneTokenStore) =>
  (pluginId: string, request: IncomingMessage, url: URL): AuthenticatedPane | undefined => {
    const queryToken = url.searchParams.get(PANE_TOKEN_QUERY_PARAM)
    if (queryToken !== null) {
      const authenticated = exchangePaneQueryToken(tokens, queryToken, pluginId)
      if (authenticated !== undefined) return authenticated
    }
    return verifyPaneCookie(tokens, pluginId, request)
  }

type PluginPane = InstalledPlugin["manifest"]["panes"][number]

const requirePluginPane = (
  plugin: InstalledPlugin,
  pluginId: string,
  tokenRequest: PluginPaneTokenRequest
): PluginPane => {
  const pane = plugin.manifest.panes.find((candidate) => candidate.type === tokenRequest.paneType)
  if (pane === undefined) {
    throw new PluginsError(
      "notFound",
      `Plugin ${pluginId} has no pane type: ${tokenRequest.paneType}`
    )
  }
  return pane
}

const paneTokenResponse = (
  pluginId: string,
  paneId: string,
  pane: PluginPane,
  issued: ReturnType<PaneTokenStore["issue"]>
): PluginPaneTokenResponse => {
  const query = new URLSearchParams({
    paneId,
    [PANE_TOKEN_QUERY_PARAM]: issued.token
  })
  return {
    expiresAt: issued.expiresAt,
    path: `/v1/plugins/${pluginId}/app${pane.path}?${query.toString()}`,
    token: issued.token
  }
}

export const issuePluginPaneToken = (
  tokens: PaneTokenStore,
  plugin: InstalledPlugin,
  pluginId: string,
  paneId: string,
  tokenRequest: PluginPaneTokenRequest
): PluginPaneTokenResponse => {
  const pane = requirePluginPane(plugin, pluginId, tokenRequest)
  const issued = tokens.issue({
    paneId,
    paneType: pane.type,
    pluginId,
    ...(tokenRequest.cwd === undefined ? {} : { cwd: tokenRequest.cwd }),
    ...(tokenRequest.themeMode === undefined ? {} : { themeMode: tokenRequest.themeMode }),
    ...(tokenRequest.workspaceId === undefined ? {} : { workspaceId: tokenRequest.workspaceId })
  })
  return paneTokenResponse(pluginId, paneId, pane, issued)
}

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
