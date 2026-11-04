import { randomUUID } from "node:crypto"

import {
  isoTimestamp,
  type McpServer,
  type PluginAccount,
  type PluginAccountOAuthStart,
  type PluginRunOAuthSpec
} from "@codevisor/api"

import { HttpFailure } from "../../server-context.js"
import type { OAuthStartInput } from "./plugin-account-flows.js"
import { newFlowId } from "./plugin-account-oauth.js"
import type { PluginAccountRecord } from "./plugin-account-store.js"

export interface PluginSignInRequest {
  readonly serverId: string
  readonly values: Readonly<Record<string, string | number | boolean>>
  readonly scopes: ReadonlyArray<string>
}

export interface PluginSignedIn {
  readonly identity?: string
  readonly label?: string
}

export type PluginSignIn = (request: PluginSignInRequest) => Promise<PluginSignedIn>

export interface PluginRunSignInDeps {
  readonly signIn: PluginSignIn | undefined
  readonly save: (record: PluginAccountRecord) => Promise<PluginAccount>
}

export const startPluginRunSignIn = (
  deps: PluginRunSignInDeps,
  server: McpServer,
  oauth: PluginRunOAuthSpec,
  input: OAuthStartInput
): PluginAccountOAuthStart => {
  const signIn = requireSignIn(deps.signIn, server)
  const request = { serverId: server.id, values: input.split.values, scopes: oauth.scopes }
  void signIn(request)
    .then((signedIn) => deps.save(signedInRecord(server, input, signedIn)))
    .catch((cause: unknown) => {
      console.error(`${server.name} sign-in failed`, cause)
    })
  return { flowId: newFlowId() }
}

const signedInRecord = (
  server: McpServer,
  input: OAuthStartInput,
  signedIn: PluginSignedIn
): PluginAccountRecord => ({
  id: input.previous?.id ?? randomUUID(),
  plugin: server.catalogId ?? server.name,
  ...labelOf(input, signedIn),
  ...(signedIn.identity === undefined ? {} : { identity: signedIn.identity }),
  method: "oauth2",
  values: input.split.values,
  secretsSet: [],
  status: "ok",
  createdAt: input.previous?.createdAt ?? isoTimestamp()
})

const labelOf = (input: OAuthStartInput, signedIn: PluginSignedIn): { readonly label?: string } => {
  const label = input.label ?? input.previous?.label ?? signedIn.label ?? signedIn.identity
  return label === undefined ? {} : { label }
}

const requireSignIn = (signIn: PluginSignIn | undefined, server: McpServer): PluginSignIn => {
  if (signIn !== undefined) return signIn
  throw new HttpFailure(501, `${server.name} can't sign in on this machine`)
}
