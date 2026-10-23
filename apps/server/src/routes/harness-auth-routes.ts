import {
  AnswerHarnessAuthRequest as AnswerHarnessAuthRequestSchema,
  CreateHarnessAccountRequest as CreateHarnessAccountRequestSchema,
  StartHarnessLoginRequest as StartHarnessLoginRequestSchema,
  UpdateHarnessAccountRequest as UpdateHarnessAccountRequestSchema
} from "@codevisor/api"

import {
  HttpFailure,
  matchRoute,
  matchRouteParams,
  readSchema,
  writeJson
} from "../server-context.js"
import { requireAuth } from "./harness-auth-services.js"
import type { AuthRouteResult, AuthServices } from "./harness-auth-services.js"
import { discoverHarnesses, discoverSettledHarnesses } from "./harnesses.js"
import { routeProviderAuth } from "./provider-auth-routes.js"
import { isMethodRoute, methodRouteParams } from "./route-context.js"
import type { RouteContext } from "./route-context.js"
import { routeParam } from "./route-params.js"
import { routeSharedHarnessAccounts } from "./shared-harness-accounts.js"

type RouteParams = Readonly<Record<string, string>>

type AccountActionHandler = (
  route: RouteContext,
  services: AuthServices,
  params: RouteParams
) => Promise<boolean>

const accountPaths = {
  refresh: "/v1/harnesses/auth/refresh",
  loginAnswer: "/v1/harnesses/:id/accounts/:accountId/login/:flowId/answer",
  login: "/v1/harnesses/:id/accounts/:accountId/login/:flowId",
  action: "/v1/harnesses/:id/accounts/:accountId/:action",
  probe: "/v1/harnesses/:id/accounts/:accountId/auth/probe",
  account: "/v1/harnesses/:id/accounts/:accountId",
  accounts: "/v1/harnesses/:id/accounts"
}

export const routeHarnessAuth = async (route: RouteContext): Promise<boolean> => {
  if (await routeSharedHarnessAccounts(route)) return true

  return routeProviderAuth(route) ?? routeAccountAuth(route) ?? false
}

const routeAccountAuth = (route: RouteContext): AuthRouteResult =>
  routeAuthRefresh(route) ??
  routeAccountLogin(route) ??
  routeAccountAction(route) ??
  routeAccountProbe(route) ??
  routeAccount(route) ??
  routeAccounts(route)

const routeAuthRefresh = (route: RouteContext): AuthRouteResult => {
  if (!isMethodRoute(route.request, route.url, "POST", accountPaths.refresh)) return undefined
  return refreshAuth(route, requireAuth(route.services))
}

const routeAccountLogin = (route: RouteContext): AuthRouteResult => {
  const answer = methodRouteParams(route, "POST", accountPaths.loginAnswer)
  if (answer !== undefined) return answerLogin(route, requireAuth(route.services), answer)

  const login = methodRouteParams(route, "DELETE", accountPaths.login)
  if (login !== undefined) return cancelLogin(route, requireAuth(route.services), login)
  return undefined
}

const routeAccountAction = (route: RouteContext): AuthRouteResult => {
  const params = methodRouteParams(route, "POST", accountPaths.action)
  if (params === undefined) return undefined

  const services = requireAuth(route.services)
  return accountActions.get(routeParam(params, "action"))?.(route, services, params)
}

const routeAccountProbe = (route: RouteContext): AuthRouteResult => {
  const params = methodRouteParams(route, "POST", accountPaths.probe)
  if (params === undefined) return undefined
  return probeAccount(route, requireAuth(route.services), params)
}

const routeAccount = (route: RouteContext): AuthRouteResult => {
  const params = matchRouteParams(route.url.pathname, accountPaths.account)
  if (params === undefined) return undefined

  const services = requireAuth(route.services)
  if (route.request.method === "PATCH") return renameAccount(route, services, params)
  if (route.request.method === "DELETE") return removeAccount(route, services, params)
  return undefined
}

const routeAccounts = (route: RouteContext): AuthRouteResult => {
  const harnessId = matchRoute(route.url.pathname, accountPaths.accounts)
  if (harnessId === undefined) return undefined

  const services = requireAuth(route.services)
  if (route.request.method === "GET") return listAccounts(route, services, harnessId)
  if (route.request.method === "POST") return createAccount(route, services, harnessId)
  return undefined
}

const refreshAuth = async (
  { response, url }: RouteContext,
  services: AuthServices
): Promise<boolean> => {
  if (url.searchParams.get("mode") === "settle") {
    writeJson(response, 200, await discoverSettledHarnesses(services))
    return true
  }
  const harnessId = requestedHarnessId(url)
  await services.auth.refresh(harnessId)
  writeJson(
    response,
    200,
    await discoverHarnesses(services, harnessId === undefined, harnessId, true)
  )
  return true
}

const answerLogin = async (
  { request, response }: RouteContext,
  services: AuthServices,
  params: RouteParams
): Promise<boolean> => {
  const payload = await readSchema(request, AnswerHarnessAuthRequestSchema)
  writeJson(
    response,
    200,
    await services.auth.answerLogin(routeParam(params, "flowId"), payload.code)
  )
  return true
}

const cancelLogin = async (
  { response }: RouteContext,
  services: AuthServices,
  params: RouteParams
): Promise<boolean> => {
  await services.auth.cancelLogin(routeParam(params, "flowId"))
  writeJson(response, 204, undefined)
  return true
}

const activateAccount: AccountActionHandler = async ({ response }, services, params) => {
  const harnessId = routeParam(params, "id")
  await services.auth.activateAccount(harnessId, routeParam(params, "accountId"))
  writeJson(response, 200, await services.auth.accounts(harnessId))
  return true
}

const beginLogin: AccountActionHandler = async ({ request, response }, services, params) => {
  const payload = await readSchema(request, StartHarnessLoginRequestSchema)
  writeJson(
    response,
    201,
    await services.auth.beginLogin(
      routeParam(params, "accountId"),
      payload.methodId,
      payload.apiKey
    )
  )
  return true
}

const logoutAccount: AccountActionHandler = async ({ response }, services, params) => {
  writeJson(response, 200, await services.auth.logout(routeParam(params, "accountId")))
  return true
}

const accountActions: ReadonlyMap<string, AccountActionHandler> = new Map([
  ["activate", activateAccount],
  ["login", beginLogin],
  ["logout", logoutAccount]
])

const probeAccount = async (
  { response }: RouteContext,
  services: AuthServices,
  params: RouteParams
): Promise<boolean> => {
  writeJson(response, 200, await services.auth.probeAccount(routeParam(params, "accountId"), true))
  return true
}

const renameAccount = async (
  { request, response }: RouteContext,
  services: AuthServices,
  params: RouteParams
): Promise<boolean> => {
  const payload = await readSchema(request, UpdateHarnessAccountRequestSchema)
  if (payload.label === undefined) throw new HttpFailure(400, "Account label is required")

  writeJson(
    response,
    200,
    await services.auth.renameAccount(routeParam(params, "accountId"), payload.label)
  )
  return true
}

const removeAccount = async (
  { response }: RouteContext,
  services: AuthServices,
  params: RouteParams
): Promise<boolean> => {
  await services.auth.removeAccount(routeParam(params, "accountId"))
  writeJson(response, 204, undefined)
  return true
}

const listAccounts = async (
  { response }: RouteContext,
  services: AuthServices,
  harnessId: string
): Promise<boolean> => {
  writeJson(response, 200, await services.auth.accounts(harnessId))
  return true
}

const createAccount = async (
  { request, response }: RouteContext,
  services: AuthServices,
  harnessId: string
): Promise<boolean> => {
  const payload = await readSchema(request, CreateHarnessAccountRequestSchema)
  writeJson(response, 201, await services.auth.createAccount(harnessId, payload.label))
  return true
}

const requestedHarnessId = (url: URL): string | undefined =>
  url.searchParams.get("harnessId")?.trim() || undefined
