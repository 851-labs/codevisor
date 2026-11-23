import { createHash } from "node:crypto"

import type { McpOAuthRelay, McpOAuthRelayRequest } from "@codevisor/mcp"

import type { CloudServerControl } from "../server-context-types.js"
import { stringField } from "../unknown-values.js"

export type OAuthRelay = McpOAuthRelay

export type OAuthRelayRequest = McpOAuthRelayRequest

export interface OAuthRelayDeps {
  readonly cloud: CloudServerControl | undefined
  readonly appScheme: string
  readonly log?: (message: string) => void
}

export const relayPaths: ReadonlySet<string> = new Set([
  "/oauth/callback",
  "/oauth/plugins/callback"
])

export const makeOAuthRelay = (deps: OAuthRelayDeps): OAuthRelay => ({
  register: async (state, request = {}) => {
    const machineRequest = signedInRequest(deps.cloud)
    if (machineRequest === undefined || !mayReachCloud(request.accepted)) return undefined

    const registered = await machineRequest(
      "POST",
      "/api/machine/oauth-flows",
      flowRegistration(state, request, deps)
    ).catch((cause: unknown) => {
      deps.log?.(`Codevisor Cloud couldn't take this sign-in, so it stays local: ${message(cause)}`)
      return undefined
    })
    return stringField(registered, "redirectUri")
  },
  signedInPage: (app) => {
    const serverUrl = deps.cloud?.serverUrl?.()
    if (deps.cloud?.deviceId() === undefined || serverUrl === undefined) return undefined

    const page = new URL(signedInPath, serverUrl)
    if (app !== undefined) page.searchParams.set("app", app)
    return page.toString()
  }
})

const signedInPath = "/oauth/signed-in"

export const oauthFlowId = (state: string): string =>
  createHash("sha256").update(state).digest("base64url")

const signedInRequest = (
  cloud: CloudServerControl | undefined
): CloudServerControl["machineRequest"] =>
  cloud?.deviceId() === undefined ? undefined : cloud.machineRequest

const mayReachCloud = (accepted: ReadonlyArray<string> | undefined): boolean =>
  accepted === undefined || accepted.some(hasRelayPath)

const hasRelayPath = (candidate: string): boolean =>
  URL.canParse(candidate) && relayPaths.has(new URL(candidate).pathname)

const flowRegistration = (
  state: string,
  request: OAuthRelayRequest,
  deps: OAuthRelayDeps
): Record<string, unknown> => ({
  flowId: oauthFlowId(state),
  app: request.app ?? deps.appScheme,
  opensApp: request.app !== undefined,
  ...(request.accepted === undefined ? {} : { redirectUris: request.accepted })
})

const message = (cause: unknown): string => (cause instanceof Error ? cause.message : String(cause))
