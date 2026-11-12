import {
  CompletePluginAccountOAuthRequest,
  SavePluginAccountRequest,
  StartPluginAccountOAuthRequest
} from "@codevisor/api"
import { Schema } from "effect"

import type { PluginAccounts } from "../plugins/accounts/plugin-accounts.js"
import { HttpFailure, matchRouteParams, readSchema, writeJson } from "../server-context.js"
import { appSchemeParameter } from "./oauth-returns.js"
import type { RouteContext } from "./route-context.js"

export const routePluginAccounts = async (route: RouteContext): Promise<boolean> => {
  const { request, url } = route
  if (url.pathname === oauthCompletePath && request.method === "POST")
    return routeOAuthComplete(route)
  const collection = matchRouteParams(url.pathname, "/v1/plugins/:serverId/accounts")
  const member = matchRouteParams(url.pathname, "/v1/plugins/:serverId/accounts/:accountId")
  const oauth = matchRouteParams(url.pathname, "/v1/plugins/:serverId/accounts/oauth/start")
  const ingress = matchRouteParams(
    url.pathname,
    "/v1/plugins/:serverId/accounts/:accountId/ingress"
  )
  if (ingress !== undefined && request.method === "GET") return routeIngress(route, ingress)
  const guide = matchRouteParams(url.pathname, "/v1/plugins/:serverId/accounts/:accountId/guide")
  if (guide !== undefined && request.method === "GET") return routeGuide(route, guide)
  if (oauth !== undefined) return routeOAuthStart(route, oauth.serverId!)
  if (collection === undefined && member === undefined) return false
  const accounts = requireAccounts(route)

  if (collection !== undefined) return routeCollection(route, accounts, collection.serverId!)
  return routeMember(route, accounts, member!.serverId!, member!.accountId!)
}

const routeOAuthStart = async (route: RouteContext, serverId: string): Promise<boolean> => {
  if (route.request.method !== "POST") return false
  const accounts = requireAccounts(route)
  const body = await readSchema(route.request, OAuthStartBody)
  const started = await accounts.startOAuth(serverId, oauthStart(body, returnApp(route)))
  rememberReturnApp(route, started.authorizationUrl)
  return respond(route, started)
}

const rememberReturnApp = (route: RouteContext, authorizationUrl: string | undefined): void => {
  if (authorizationUrl === undefined) return

  route.routeState.oauthReturns.remember(authorizationUrl, returnApp(route))
}

const returnApp = (route: RouteContext): string | undefined =>
  route.url.searchParams.get(appSchemeParameter) ?? undefined

const oauthCompletePath = "/v1/plugins/oauth/complete"

const routeOAuthComplete = async (route: RouteContext): Promise<boolean> => {
  const accounts = requireAccounts(route)
  const body = await readSchema(route.request, CompletePluginAccountOAuthRequest)
  const callback = callbackParams(body.callbackUrl)
  await accounts.completeOAuth(callback.state, callback.code, callback.error)
  return respond(route, { completed: true })
}

interface OAuthCallbackParams {
  readonly state: string
  readonly code?: string
  readonly error?: string
}

const callbackParams = (callbackUrl: string): OAuthCallbackParams => {
  const params = parsedUrl(callbackUrl).searchParams
  const code = params.get("code")
  const error = params.get("error")
  return {
    state: params.get("state") ?? "",
    ...(code === null ? {} : { code }),
    ...(error === null ? {} : { error })
  }
}

const parsedUrl = (callbackUrl: string): URL => {
  if (!URL.canParse(callbackUrl)) throw new HttpFailure(400, "That isn't a sign-in callback URL")
  return new URL(callbackUrl)
}

const routeIngress = async (
  route: RouteContext,
  params: Record<string, string>
): Promise<boolean> => {
  const events = route.routeState.pluginEvents
  if (events === undefined) throw new HttpFailure(501, "Plugin events unavailable")
  return respond(route, { ingress: await events.ingressUrls(params.serverId!, params.accountId!) })
}

const routeGuide = async (
  route: RouteContext,
  params: Record<string, string>
): Promise<boolean> => {
  const accounts = requireAccounts(route)
  const serverId = params.serverId!
  const accountId = params.accountId!
  const events = route.routeState.pluginEvents
  const ingress = async () => (await events?.ingressUrls(serverId, accountId)) ?? []
  return respond(route, await accounts.guide(serverId, accountId, ingress))
}

const OAuthStartBody = Schema.Struct({
  ...StartPluginAccountOAuthRequest.fields,
  values: Schema.optional(Schema.Record(Schema.String, Schema.Unknown))
})

const routeCollection = async (
  route: RouteContext,
  accounts: PluginAccounts,
  serverId: string
): Promise<boolean> => {
  if (route.request.method === "GET") {
    return respond(route, { accounts: await accounts.list(serverId) })
  }
  if (route.request.method !== "POST") return false
  const body = await readSchema(route.request, SavePluginAccountRequest)
  return respond(route, await accounts.saveFields(serverId, body))
}

const routeMember = async (
  route: RouteContext,
  accounts: PluginAccounts,
  serverId: string,
  accountId: string
): Promise<boolean> => {
  if (route.request.method === "DELETE") {
    await accounts.remove(serverId, accountId)
    return respond(route, { removed: true })
  }
  if (route.request.method !== "PUT") return false
  const body = await readSchema(route.request, SavePluginAccountRequest)
  return respond(route, await accounts.saveFields(serverId, body, accountId))
}

const oauthStart = (body: typeof OAuthStartBody.Type, app: string | undefined) => ({
  values: body.values ?? {},
  ...(body.label === undefined ? {} : { label: body.label }),
  ...(body.accountId === undefined ? {} : { accountId: body.accountId }),
  ...(app === undefined ? {} : { callbackScheme: app })
})

const respond = (route: RouteContext, body: unknown): boolean => {
  writeJson(route.response, 200, body)
  return true
}

const requireAccounts = (route: RouteContext): PluginAccounts => {
  const platform = route.services.pluginPlatform
  if (platform === undefined) throw new HttpFailure(501, "Plugins unavailable")
  return platform.accounts
}
