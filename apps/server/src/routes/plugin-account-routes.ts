import { SavePluginAccountRequest, StartPluginAccountOAuthRequest } from "@codevisor/api"
import { Schema } from "effect"

import type { PluginAccounts } from "../plugins/accounts/plugin-accounts.js"
import { HttpFailure, matchRouteParams, readSchema, writeJson } from "../server-context.js"
import type { RouteContext } from "./route-context.js"

export const routePluginAccounts = async (route: RouteContext): Promise<boolean> => {
  const { request, url } = route
  const collection = matchRouteParams(url.pathname, "/v1/plugins/:serverId/accounts")
  const member = matchRouteParams(url.pathname, "/v1/plugins/:serverId/accounts/:accountId")
  const oauth = matchRouteParams(url.pathname, "/v1/plugins/:serverId/accounts/oauth/start")
  const ingress = matchRouteParams(
    url.pathname,
    "/v1/plugins/:serverId/accounts/:accountId/ingress"
  )
  if (ingress !== undefined && request.method === "GET") return routeIngress(route, ingress)
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
  return respond(route, await accounts.startOAuth(serverId, oauthStart(body)))
}

const routeIngress = async (
  route: RouteContext,
  params: Record<string, string>
): Promise<boolean> => {
  const events = route.routeState.pluginEvents
  if (events === undefined) throw new HttpFailure(501, "Plugin events unavailable")
  return respond(route, { ingress: await events.ingressUrls(params.serverId!, params.accountId!) })
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

const oauthStart = (body: typeof OAuthStartBody.Type) => ({
  values: body.values ?? {},
  ...(body.label === undefined ? {} : { label: body.label }),
  ...(body.accountId === undefined ? {} : { accountId: body.accountId })
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
