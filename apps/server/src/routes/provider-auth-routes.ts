import {
  AnswerOpenCodeAuthRequest as AnswerOpenCodeAuthRequestSchema,
  AnswerPiAuthRequest as AnswerPiAuthRequestSchema,
  StartOpenCodeAuthRequest as StartOpenCodeAuthRequestSchema,
  StartPiAuthRequest as StartPiAuthRequestSchema
} from "@codevisor/api"

import { matchRouteParams, readSchema, writeJson } from "../server-context.js"
import { requireAuthMethods } from "./harness-auth-services.js"
import type { AuthRouteResult, AuthServices, OptionalAuthMethod } from "./harness-auth-services.js"
import { isRoute, methodRouteParams } from "./route-context.js"
import type { RouteContext } from "./route-context.js"
import { routeParam } from "./route-params.js"

type RouteParams = Readonly<Record<string, string>>

interface ProviderAuthRoute {
  readonly match: (route: RouteContext) => RouteParams | undefined
  readonly handle: (route: RouteContext, params: RouteParams) => AuthRouteResult
}

type AuthHandler<K extends OptionalAuthMethod> = (
  route: RouteContext,
  services: AuthServices<K>,
  params: RouteParams
) => true | Promise<boolean>

export const routeProviderAuth = (route: RouteContext): AuthRouteResult => {
  for (const providerRoute of providerAuthRoutes) {
    const params = providerRoute.match(route)
    if (params === undefined) continue

    const result = providerRoute.handle(route, params)
    if (result !== undefined) return result
  }
  return undefined
}

const methodRoute = <K extends OptionalAuthMethod>(
  method: string,
  pattern: string,
  requires: K,
  handler: AuthHandler<K>
): ProviderAuthRoute => ({
  match: (route) => methodRouteParams(route, method, pattern),
  handle: (route, params) => handler(route, requireAuthMethods(route.services, requires), params)
})

const exactRoute = <K extends OptionalAuthMethod>(
  method: string,
  pathname: string,
  requires: K,
  handler: AuthHandler<K>
): ProviderAuthRoute => ({
  match: ({ url, request }) => (isRoute(url, request, pathname, method) ? {} : undefined),
  handle: (route, params) => handler(route, requireAuthMethods(route.services, requires), params)
})

const pathRoute = (
  pattern: string,
  handle: (route: RouteContext, params: RouteParams) => AuthRouteResult
): ProviderAuthRoute => ({
  match: ({ url }) => matchRouteParams(url.pathname, pattern),
  handle
})

const routeOpenCodeFlow = (route: RouteContext, params: RouteParams): AuthRouteResult => {
  const services = requireAuthMethods(route.services, "openCodeLoginFlow", "cancelOpenCodeLogin")
  if (route.request.method === "GET") return writeOpenCodeFlow(route, services, params)
  if (route.request.method === "DELETE") return cancelOpenCodeFlow(route, services, params)
  return undefined
}

const routePiFlow = (route: RouteContext, params: RouteParams): AuthRouteResult => {
  const { services, request } = route
  if (request.method === "GET") {
    return writePiFlow(route, requireAuthMethods(services, "piLoginFlow"), params)
  }
  if (request.method === "DELETE") {
    return cancelPiFlow(route, requireAuthMethods(services, "cancelPiLogin"), params)
  }
  return undefined
}

const listOpenCodeProviders: AuthHandler<"openCodeProviders"> = async (
  { response },
  services,
  params
) => {
  writeJson(response, 200, await services.auth.openCodeProviders(routeParam(params, "accountId")))
  return true
}

const beginOpenCodeLogin: AuthHandler<"beginOpenCodeLogin"> = async (
  { request, response },
  services,
  params
) => {
  const payload = await readSchema(request, StartOpenCodeAuthRequestSchema)
  writeJson(
    response,
    201,
    await services.auth.beginOpenCodeLogin(
      routeParam(params, "accountId"),
      routeParam(params, "providerId"),
      payload.methodId,
      payload.inputs,
      payload.apiKey
    )
  )
  return true
}

const logoutOpenCodeProvider: AuthHandler<"logoutOpenCodeProvider"> = async (
  { response },
  services,
  params
) => {
  await services.auth.logoutOpenCodeProvider(
    routeParam(params, "accountId"),
    routeParam(params, "providerId")
  )
  writeJson(response, 204, undefined)
  return true
}

const answerOpenCodeLogin: AuthHandler<"answerOpenCodeLogin"> = async (
  { request, response },
  services,
  params
) => {
  const payload = await readSchema(request, AnswerOpenCodeAuthRequestSchema)
  writeJson(
    response,
    200,
    await services.auth.answerOpenCodeLogin(routeParam(params, "flowId"), payload.code)
  )
  return true
}

const writeOpenCodeFlow: AuthHandler<"openCodeLoginFlow"> = ({ response }, services, params) => {
  writeJson(response, 200, services.auth.openCodeLoginFlow(routeParam(params, "flowId")))
  return true
}

const cancelOpenCodeFlow: AuthHandler<"cancelOpenCodeLogin"> = ({ response }, services, params) => {
  services.auth.cancelOpenCodeLogin(routeParam(params, "flowId"))
  writeJson(response, 204, undefined)
  return true
}

const listPiProviders: AuthHandler<"piProviders"> = async ({ response }, services) => {
  writeJson(response, 200, await services.auth.piProviders())
  return true
}

const beginPiLogin: AuthHandler<"beginPiLogin"> = async (
  { request, response },
  services,
  params
) => {
  const payload = await readSchema(request, StartPiAuthRequestSchema)
  writeJson(
    response,
    201,
    await services.auth.beginPiLogin(routeParam(params, "providerId"), payload.method)
  )
  return true
}

const logoutPiProvider: AuthHandler<"logoutPiProvider"> = async (
  { response },
  services,
  params
) => {
  await services.auth.logoutPiProvider(routeParam(params, "providerId"))
  writeJson(response, 204, undefined)
  return true
}

const answerPiLogin: AuthHandler<"answerPiLogin"> = async (
  { request, response },
  services,
  params
) => {
  const payload = await readSchema(request, AnswerPiAuthRequestSchema)
  writeJson(
    response,
    200,
    await services.auth.answerPiLogin(routeParam(params, "flowId"), payload.value)
  )
  return true
}

const writePiFlow: AuthHandler<"piLoginFlow"> = ({ response }, services, params) => {
  writeJson(response, 200, services.auth.piLoginFlow(routeParam(params, "flowId")))
  return true
}

const cancelPiFlow: AuthHandler<"cancelPiLogin"> = ({ response }, services, params) => {
  services.auth.cancelPiLogin(routeParam(params, "flowId"))
  writeJson(response, 204, undefined)
  return true
}

const providerAuthRoutes: ReadonlyArray<ProviderAuthRoute> = [
  methodRoute(
    "GET",
    "/v1/harnesses/opencode/accounts/:accountId/providers",
    "openCodeProviders",
    listOpenCodeProviders
  ),
  methodRoute(
    "POST",
    "/v1/harnesses/opencode/accounts/:accountId/providers/:providerId/login",
    "beginOpenCodeLogin",
    beginOpenCodeLogin
  ),
  methodRoute(
    "DELETE",
    "/v1/harnesses/opencode/accounts/:accountId/providers/:providerId",
    "logoutOpenCodeProvider",
    logoutOpenCodeProvider
  ),
  methodRoute(
    "POST",
    "/v1/harnesses/opencode/auth-flows/:flowId/answer",
    "answerOpenCodeLogin",
    answerOpenCodeLogin
  ),
  pathRoute("/v1/harnesses/opencode/auth-flows/:flowId", routeOpenCodeFlow),
  exactRoute("GET", "/v1/harnesses/pi/providers", "piProviders", listPiProviders),
  methodRoute("POST", "/v1/harnesses/pi/providers/:providerId/login", "beginPiLogin", beginPiLogin),
  methodRoute(
    "DELETE",
    "/v1/harnesses/pi/providers/:providerId",
    "logoutPiProvider",
    logoutPiProvider
  ),
  methodRoute("POST", "/v1/harnesses/pi/auth-flows/:flowId/answer", "answerPiLogin", answerPiLogin),
  pathRoute("/v1/harnesses/pi/auth-flows/:flowId", routePiFlow)
]
