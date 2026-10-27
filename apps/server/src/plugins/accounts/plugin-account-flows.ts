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
import type { SplitFieldValues } from "./plugin-account-fields.js"
import {
  beginPluginOAuth,
  exchangePluginCode,
  fetchIdentity,
  flowState,
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

export interface OAuthRedirect {
  readonly redirectUri: string
  readonly deviceId: string
}

export interface OAuthRedirects {
  readonly prepare: (flowId: string) => Promise<OAuthRedirect>
}

export interface OAuthStartInput {
  readonly label?: string
  readonly previous: PluginAccountRecord | undefined
  readonly split: SplitFieldValues
}

export interface PluginOAuthFlowsDeps {
  readonly vault: PluginVault
  readonly redirects: OAuthRedirects
  readonly now: () => number
  readonly fetch?: typeof fetch
  readonly save: (record: PluginAccountRecord) => Promise<PluginAccount>
}

export const makePluginOAuthFlows = (deps: PluginOAuthFlowsDeps) => {
  const pending = new Map<
    string,
    { readonly flow: PendingOAuthFlow; readonly spec: PluginOAuthSpec }
  >()

  const forgetExpired = (): void => {
    for (const [flowId, entry] of pending)
      if (entry.flow.expiresAt < deps.now()) pending.delete(flowId)
  }

  const takeFlow = (state: string) => {
    forgetExpired()
    const parsed = parseFlowState(state)
    const entry = parsed === undefined ? undefined : pending.get(parsed.flowId)
    if (entry === undefined || entry.flow.nonce !== parsed?.nonce) return undefined
    pending.delete(entry.flow.flowId)
    return entry
  }

  const finish = async (flow: PendingOAuthFlow, spec: PluginOAuthSpec, code: string) => {
    const tokens = await exchangePluginCode(spec, flow, code, deps.fetch)
    const identity =
      (await fetchIdentity(spec, tokens.access_token, deps.fetch)) ?? flow.label ?? "Account"
    const credential = await deps.vault.create(
      oauthBundle(spec, flow, tokens, identity, deps.now())
    )
    await deps.save(oauthRecord(flow, identity, tokens.scope, credential))
  }

  return {
    start: async (
      server: McpServer,
      spec: PluginAccountSpec,
      input: OAuthStartInput
    ): Promise<PluginAccountOAuthStart> => {
      const oauth = requireOAuth(spec, server)
      const flowId = newFlowId()
      const nonce = newNonce()
      const redirect = await deps.redirects.prepare(flowId)
      const client = oauthClient(oauth, input.split)
      const started = await beginPluginOAuth(
        oauth,
        client,
        redirect.redirectUri,
        flowState(flowId, redirect.deviceId, nonce)
      )
      pending.set(flowId, {
        spec: oauth,
        flow: pendingFlow(server, input, {
          flowId,
          nonce,
          client,
          redirect,
          started,
          expiresAt: deps.now() + oauthFlowLifetimeMs
        })
      })
      return { flowId, authorizationUrl: started.authorizationUrl }
    },
    owns: (state: string): boolean => {
      const parsed = parseFlowState(state)
      return parsed !== undefined && pending.has(parsed.flowId)
    },
    complete: async (state: string, code: string | undefined, error?: string): Promise<void> => {
      const entry = takeFlow(state)
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
  readonly redirect: OAuthRedirect
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
  redirectUri: parts.redirect.redirectUri,
  codeVerifier: parts.started.codeVerifier,
  expiresAt: parts.expiresAt
})

const flowLabel = (input: OAuthStartInput): { readonly label?: string } => {
  const label = input.label ?? input.previous?.label
  return label === undefined ? {} : { label }
}

const oauthRecord = (
  flow: PendingOAuthFlow,
  identity: string,
  scope: string | undefined,
  credential: { readonly id: string; readonly key: string }
): PluginAccountRecord => ({
  id: flow.accountId ?? randomUUID(),
  plugin: flow.plugin,
  label: flow.label ?? identity,
  identity,
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

const oauthClient = (oauth: PluginOAuthSpec, split: SplitFieldValues): OAuthClient => {
  if (oauth.client === "managed")
    throw new HttpFailure(400, "Codevisor's shared client isn't available yet")
  const clientId = split.values.clientId
  if (typeof clientId !== "string") throw new HttpFailure(400, "OAuth client ID is required")
  const clientSecret = split.secrets.clientSecret
  return { clientId, ...(clientSecret === undefined ? {} : { clientSecret }) }
}
