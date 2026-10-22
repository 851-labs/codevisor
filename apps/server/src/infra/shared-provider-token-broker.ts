import type { IncomingMessage, ServerResponse } from "node:http"

import {
  MANAGED_REFRESH_PREFIX,
  providerCredential,
  SharedCredentialError,
  type SharedCredentialVault,
  type SharedTokenBundle
} from "@codevisor/harness-manager"
import { Schema } from "effect"

import { BoundedBody, isLocalhost } from "../server-http.js"
import { field, isRecord } from "../unknown-values.js"
import type { SharedProviderRecord, SharedProviderStore } from "./shared-provider-store.js"

const Capability = Schema.Struct({
  capability: Schema.String,
  slot: Schema.String,
  credentialId: Schema.String
})
export type Capability = typeof Capability.Type
export const isCapability = Schema.is(Capability)

interface TokenRequest {
  readonly body: Readonly<Record<string, unknown>>
  readonly rejectedAccessToken: string | undefined
}
type LocalEntries = Awaited<ReturnType<SharedProviderStore["localEntries"]>>

const maxTokenRequestBytes = 16_384

export const makeProviderTokenBroker =
  (store: SharedProviderStore, vault: SharedCredentialVault) =>
  async (request: IncomingMessage, response: ServerResponse): Promise<void> => {
    response.setHeader("Cache-Control", "no-store")
    if (isForeignCaller(request)) return reply(response, 403)
    if (request.method !== "POST") return reply(response, 405)

    const bearer = capabilityBearer(request)
    const cap = presentedCapability(await store.localEntries(), bearer)
    if (!bearer || !cap) return reply(response, 401)

    const row = grantedRecord(await store.get(cap.slot), cap)
    if (row === undefined) return reply(response, 401)

    try {
      const received = new BoundedBody(maxTokenRequestBytes)
      for await (const chunk of request) if (!received.accept(chunk)) return reply(response, 413)

      const tokenRequest = readTokenRequest(received)
      if (tokenRequest === undefined) return reply(response, 400)

      let token = await vault.token(row.credential, tokenRequest.rejectedAccessToken)
      if (forcesRefresh(tokenRequest.body, row))
        token = await vault.token(row.credential, token.accessToken)
      response
        .writeHead(200, { "Content-Type": "application/json" })
        .end(JSON.stringify(tokenReply(token, cap)))
    } catch (cause) {
      response
        .writeHead(failureStatus(cause), { "Content-Type": "application/json" })
        .end(JSON.stringify({ error: "Reconnect this account in Codevisor." }))
    }
  }

const reply = (response: ServerResponse, status: number): void => {
  response.writeHead(status).end()
}

const isForeignCaller = (request: IncomingMessage): boolean =>
  request.headers.origin !== undefined || !isLocalhost(request.socket.remoteAddress)

const capabilityBearer = (request: IncomingMessage): string | undefined =>
  request.headers.authorization?.match(/^Bearer ([\w-]{43})$/)?.[1]

const presentedCapability = (
  entries: LocalEntries,
  bearer: string | undefined
): Capability | undefined =>
  entries
    .filter((entry) => entry.key.startsWith("cap:"))
    .map((entry) => entry.value)
    .filter(isCapability)
    .find((value) => value.capability === bearer)

const grantedRecord = (
  row: SharedProviderRecord | undefined,
  cap: Capability
): SharedProviderRecord | undefined => {
  if (!row || row.credential.id !== cap.credentialId) return undefined
  return row
}

const readTokenRequest = (received: BoundedBody): TokenRequest | undefined => {
  let body: unknown
  try {
    body = JSON.parse(received.text())
  } catch {
    return undefined
  }
  const rejectedAccessToken = field(body, "rejectedAccessToken")
  if (!isRecord(body) || !isOptionalString(rejectedAccessToken)) return undefined
  return { body, rejectedAccessToken }
}

const isOptionalString = (value: unknown): value is string | undefined =>
  value === undefined || typeof value === "string"

const forcesRefresh = (body: TokenRequest["body"], row: SharedProviderRecord): boolean =>
  body.force === true && row.harnessId === "grok-build"

const tokenReply = (token: SharedTokenBundle, cap: Capability) => ({
  credential: providerCredential(token, MANAGED_REFRESH_PREFIX + cap.capability),
  ...(token.idToken ? { idToken: token.idToken } : {}),
  access_token: token.accessToken,
  expires_in: Math.max(1, Math.floor((token.expiresAt - Date.now()) / 1000)),
  issuer: "https://auth.x.ai"
})

const failureStatus = (cause: unknown): number =>
  cause instanceof SharedCredentialError && cause.reason === "revoked" ? 401 : 503
