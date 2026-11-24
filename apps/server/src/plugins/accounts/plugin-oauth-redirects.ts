import type { PluginOAuthSpec } from "@codevisor/api"
import type { McpOAuthRelay } from "@codevisor/mcp"

import { HttpFailure } from "../../server-context.js"
import { flowState, type OAuthClient } from "./plugin-account-oauth.js"

export interface OAuthRedirects {
  readonly loopbackUri: string
  readonly relay?: McpOAuthRelay | undefined
}

export interface PlannedRedirect {
  readonly redirectUri: string
  readonly state: string
  readonly callbackScheme?: string
}

export interface RedirectRequest {
  readonly oauth: PluginOAuthSpec
  readonly client: OAuthClient
  readonly flowId: string
  readonly nonce: string
  readonly callbackScheme?: string | undefined
  readonly crossDevice?: boolean
}

export const appCallbackSchemePattern = /^codevisor(-dev(-[0-9a-f]{10})?)?$/

export const planRedirect = async (
  request: RedirectRequest,
  redirects: OAuthRedirects
): Promise<PlannedRedirect> => {
  const relayed = await relayedRedirect(request, redirects.relay)
  if (relayed !== undefined) return relayed
  if (request.oauth.redirectUrl !== undefined)
    return appRedirect(request, request.oauth.redirectUrl)
  if (request.crossDevice === true)
    throw new HttpFailure(409, loopbackOnlyMessage, "signInNeedsMachine")

  return {
    redirectUri: redirects.loopbackUri,
    state: flowState(request.flowId, "local", request.nonce)
  }
}

const relayedReturn = "cloud"

const relayedRedirect = async (
  request: RedirectRequest,
  relay: McpOAuthRelay | undefined
): Promise<PlannedRedirect | undefined> => {
  const accepted = acceptedRedirects(request)
  if (relay === undefined || accepted === undefined) return undefined

  const state = flowState(request.flowId, relayedReturn, request.nonce)
  const app = request.callbackScheme
  const redirectUri = await relay.register(state, {
    accepted,
    ...(app === undefined ? {} : { app })
  })
  return redirectUri === undefined ? undefined : { redirectUri, state }
}

const acceptedRedirects = (request: RedirectRequest): ReadonlyArray<string> | undefined => {
  if (request.oauth.redirectUrl !== undefined) return [request.oauth.redirectUrl]

  return request.client.redirectUris
}

const appRedirect = (request: RedirectRequest, redirectUri: string): PlannedRedirect => {
  const scheme = request.callbackScheme
  if (scheme === undefined || !appCallbackSchemePattern.test(scheme))
    throw new HttpFailure(400, appOnlyMessage)

  return {
    redirectUri,
    state: flowState(request.flowId, scheme, request.nonce),
    callbackScheme: scheme
  }
}

const loopbackOnlyMessage =
  "This sign-in can only finish in a browser on the machine the plugin runs on, because that machine can't take it through Codevisor Cloud. Sign that machine in to Codevisor Cloud, or sign in from Codevisor on that machine"

const appOnlyMessage =
  "Start this sign-in from the Codevisor app, or sign this machine in to Codevisor Cloud so it can finish from any device"
