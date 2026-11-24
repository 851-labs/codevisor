import { randomUUID } from "node:crypto"

import {
  isoTimestamp,
  type McpServer,
  type PluginAccount,
  type PluginAccountOAuthStart,
  type PluginAccountSpec,
  type PluginOAuthSpec
} from "@codevisor/api"

import { HttpFailure } from "../../server-context.js"
import { type InstalledOAuthClients, noInstalledOAuthClients } from "./installed-oauth-clients.js"
import type { SplitFieldValues } from "./plugin-account-fields.js"
import {
  beginPluginOAuth,
  exchangePluginCode,
  fetchAccountIdentity,
  type AccountIdentity,
  newFlowId,
  newNonce,
  oauthBundle,
  oauthFlowLifetimeMs,
  parseFlowState,
  type OAuthClient,
  type PendingOAuthFlow
} from "./plugin-account-oauth.js"
import type { PluginAccountRecord } from "./plugin-account-store.js"
import type { PluginVault } from "./plugin-accounts.js"
import {
  makePendingOAuthFlows,
  memoryPendingOAuthStorage,
  type PendingOAuthStorage
} from "./plugin-oauth-pending.js"
import { type OAuthRedirects, planRedirect } from "./plugin-oauth-redirects.js"

export interface OAuthStartInput {
  readonly label?: string
  readonly callbackScheme?: string
  readonly crossDevice?: boolean
  readonly previous: PluginAccountRecord | undefined
  readonly split: SplitFieldValues
}

export interface PluginOAuthFlowsDeps {
  readonly vault: PluginVault
  readonly redirects: OAuthRedirects
  readonly pendingStorage?: PendingOAuthStorage | undefined
  readonly installedClients?: InstalledOAuthClients | undefined
  readonly now: () => number
  readonly fetch?: typeof fetch
  readonly save: (record: PluginAccountRecord) => Promise<PluginAccount>
}

export const makePluginOAuthFlows = (deps: PluginOAuthFlowsDeps) => {
  const installedClients = deps.installedClients ?? noInstalledOAuthClients
  const pending = makePendingOAuthFlows(
    deps.pendingStorage ?? memoryPendingOAuthStorage(),
    deps.now
  )

  const takeFlow = async (state: string) => {
    const parsed = parseFlowState(state)
    return parsed === undefined ? undefined : pending.take(parsed.flowId, parsed.nonce)
  }

  const finish = async (flow: PendingOAuthFlow, spec: PluginOAuthSpec, code: string) => {
    const tokens = await exchangePluginCode(spec, flow, code, deps.fetch)
    const found = await fetchAccountIdentity(spec, tokens.access_token, deps.fetch)
    const identity = found.identity ?? flow.label ?? "Account"
    const credential = await deps.vault.create(
      oauthBundle(spec, flow, tokens, identity, deps.now())
    )
    await deps.save(oauthRecord(flow, { ...found, identity }, tokens.scope, credential))
  }

  return {
    start: async (
      server: McpServer,
      spec: PluginAccountSpec,
      input: OAuthStartInput
    ): Promise<PluginAccountOAuthStart> => {
      const oauth = requireOAuth(spec, server)
      const client = await oauthClient(server, oauth, input.split, installedClients)
      const flowId = newFlowId()
      const nonce = newNonce()
      const redirect = await planRedirect(
        {
          oauth,
          client,
          flowId,
          nonce,
          callbackScheme: input.callbackScheme,
          crossDevice: input.crossDevice === true
        },
        deps.redirects
      )
      const started = await beginPluginOAuth(oauth, client, redirect.redirectUri, redirect.state)
      await pending.add({
        spec: oauth,
        flow: pendingFlow(server, input, {
          flowId,
          nonce,
          client,
          redirectUri: redirect.redirectUri,
          started,
          expiresAt: deps.now() + oauthFlowLifetimeMs
        })
      })
      return {
        flowId,
        authorizationUrl: started.authorizationUrl,
        ...(redirect.callbackScheme === undefined
          ? {}
          : { callbackScheme: redirect.callbackScheme })
      }
    },
    owns: async (state: string): Promise<boolean> => {
      const parsed = parseFlowState(state)
      return parsed !== undefined && (await pending.has(parsed.flowId))
    },
    complete: async (state: string, code: string | undefined, error?: string): Promise<void> => {
      const entry = await takeFlow(state)
      if (entry === undefined) throw new HttpFailure(400, "This sign-in link expired. Start again.")
      if (code === undefined)
        throw new HttpFailure(400, `Sign-in was cancelled (${error ?? "no code"})`)
      await finish(entry.flow, entry.spec, code)
    }
  }
}

interface FlowParts {
  readonly flowId: string
  readonly nonce: string
  readonly client: OAuthClient
  readonly redirectUri: string
  readonly started: { readonly codeVerifier: string }
  readonly expiresAt: number
}

const pendingFlow = (
  server: McpServer,
  input: OAuthStartInput,
  parts: FlowParts
): PendingOAuthFlow => ({
  flowId: parts.flowId,
  nonce: parts.nonce,
  serverId: server.id,
  plugin: server.catalogId ?? server.name,
  ...(input.previous === undefined ? {} : { accountId: input.previous.id }),
  ...flowLabel(input),
  values: input.split.values,
  secrets: input.split.secrets,
  client: parts.client,
  redirectUri: parts.redirectUri,
  codeVerifier: parts.started.codeVerifier,
  expiresAt: parts.expiresAt
})

const flowLabel = (input: OAuthStartInput): { readonly label?: string } => {
  const label = input.label ?? input.previous?.label
  return label === undefined ? {} : { label }
}

const oauthRecord = (
  flow: PendingOAuthFlow,
  found: AccountIdentity & { readonly identity: string },
  scope: string | undefined,
  credential: { readonly id: string; readonly key: string }
): PluginAccountRecord => ({
  id: flow.accountId ?? randomUUID(),
  plugin: flow.plugin,
  label: flow.label ?? found.identity,
  identity: found.identity,
  ...(found.routeKey === undefined ? {} : { routeKey: found.routeKey }),
  method: "oauth2",
  values: flow.values,
  secretsSet: Object.keys(flow.secrets).toSorted(),
  ...(scope === undefined ? {} : { scopes: scope.split(" ") }),
  status: "ok",
  createdAt: isoTimestamp(),
  credential
})

const requireOAuth = (spec: PluginAccountSpec, server: McpServer): PluginOAuthSpec => {
  if (spec.oauth !== undefined) return spec.oauth
  throw new HttpFailure(400, `${server.name} doesn't sign in with OAuth`)
}

const oauthClient = async (
  server: McpServer,
  oauth: PluginOAuthSpec,
  split: SplitFieldValues,
  installedClients: InstalledOAuthClients
): Promise<OAuthClient> => {
  if (oauth.client === "managed")
    throw new HttpFailure(400, "Codevisor's shared client isn't available yet")
  if (oauth.client === "installed") return installedClient(server, oauth, installedClients)

  return userClient(split)
}

const installedClient = async (
  server: McpServer,
  oauth: PluginOAuthSpec,
  installedClients: InstalledOAuthClients
): Promise<OAuthClient> => {
  const client = await installedClients(oauth.provider)
  if (client !== undefined) return client

  throw new HttpFailure(409, `${server.name} sign-in isn't set up in this build of Codevisor`)
}

const userClient = (split: SplitFieldValues): OAuthClient => {
  const clientId = split.values.clientId
  if (typeof clientId !== "string") throw new HttpFailure(400, "OAuth client ID is required")
  const clientSecret = split.secrets.clientSecret
  return { clientId, ...(clientSecret === undefined ? {} : { clientSecret }) }
}
