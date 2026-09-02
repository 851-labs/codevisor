import {
  AnswerHarnessAuthRequest as AnswerHarnessAuthRequestSchema,
  AnswerOpenCodeAuthRequest as AnswerOpenCodeAuthRequestSchema,
  AnswerPiAuthRequest as AnswerPiAuthRequestSchema,
  CreateHarnessAccountRequest as CreateHarnessAccountRequestSchema,
  StartHarnessLoginRequest as StartHarnessLoginRequestSchema,
  StartOpenCodeAuthRequest as StartOpenCodeAuthRequestSchema,
  StartPiAuthRequest as StartPiAuthRequestSchema,
  UpdateHarnessAccountRequest as UpdateHarnessAccountRequestSchema
} from "@codevisor/api"
import type { IncomingMessage, ServerResponse } from "node:http"
import {
  HttpFailure,
  matchRoute,
  matchRouteParams,
  readSchema,
  writeJson
} from "../server-context.js"
import type { CodevisorServerServices } from "../server-context.js"
import { discoverHarnesses } from "./harnesses.js"

/// Harness authentication routes: OpenCode and Pi provider flows, auth
/// refresh, and per-harness account management.

export const routeHarnessAuth = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  const openCodeProviders = matchRouteParams(
    url.pathname,
    "/v1/harnesses/opencode/accounts/:accountId/providers"
  )
  if (openCodeProviders !== undefined && request.method === "GET") {
    if (services.auth?.openCodeProviders === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    writeJson(response, 200, await services.auth.openCodeProviders(openCodeProviders.accountId!))
    return true
  }

  const openCodeProviderLogin = matchRouteParams(
    url.pathname,
    "/v1/harnesses/opencode/accounts/:accountId/providers/:providerId/login"
  )
  if (openCodeProviderLogin !== undefined && request.method === "POST") {
    if (services.auth?.beginOpenCodeLogin === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    const payload = await readSchema(request, StartOpenCodeAuthRequestSchema)
    writeJson(
      response,
      201,
      await services.auth.beginOpenCodeLogin(
        openCodeProviderLogin.accountId!,
        openCodeProviderLogin.providerId!,
        payload.methodId,
        payload.inputs,
        payload.apiKey
      )
    )
    return true
  }

  const openCodeProvider = matchRouteParams(
    url.pathname,
    "/v1/harnesses/opencode/accounts/:accountId/providers/:providerId"
  )
  if (openCodeProvider !== undefined && request.method === "DELETE") {
    if (services.auth?.logoutOpenCodeProvider === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    await services.auth.logoutOpenCodeProvider(
      openCodeProvider.accountId!,
      openCodeProvider.providerId!
    )
    writeJson(response, 204, undefined)
    return true
  }

  const openCodeFlowAnswer = matchRouteParams(
    url.pathname,
    "/v1/harnesses/opencode/auth-flows/:flowId/answer"
  )
  if (openCodeFlowAnswer !== undefined && request.method === "POST") {
    if (services.auth?.answerOpenCodeLogin === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    const payload = await readSchema(request, AnswerOpenCodeAuthRequestSchema)
    writeJson(
      response,
      200,
      await services.auth.answerOpenCodeLogin(openCodeFlowAnswer.flowId!, payload.code)
    )
    return true
  }

  const openCodeFlow = matchRouteParams(url.pathname, "/v1/harnesses/opencode/auth-flows/:flowId")
  if (openCodeFlow !== undefined) {
    if (
      services.auth?.openCodeLoginFlow === undefined ||
      services.auth.cancelOpenCodeLogin === undefined
    ) {
      throw new HttpFailure(501, "Harness authentication unavailable")
    }
    if (request.method === "GET") {
      writeJson(response, 200, services.auth.openCodeLoginFlow(openCodeFlow.flowId!))
      return true
    }
    if (request.method === "DELETE") {
      services.auth.cancelOpenCodeLogin(openCodeFlow.flowId!)
      writeJson(response, 204, undefined)
      return true
    }
  }

  if (url.pathname === "/v1/harnesses/pi/providers" && request.method === "GET") {
    if (services.auth?.piProviders === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    writeJson(response, 200, await services.auth.piProviders())
    return true
  }

  const piProviderLogin = matchRouteParams(
    url.pathname,
    "/v1/harnesses/pi/providers/:providerId/login"
  )
  if (piProviderLogin !== undefined && request.method === "POST") {
    if (services.auth?.beginPiLogin === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    const payload = await readSchema(request, StartPiAuthRequestSchema)
    writeJson(
      response,
      201,
      await services.auth.beginPiLogin(piProviderLogin.providerId!, payload.method)
    )
    return true
  }

  const piProvider = matchRouteParams(url.pathname, "/v1/harnesses/pi/providers/:providerId")
  if (piProvider !== undefined && request.method === "DELETE") {
    if (services.auth?.logoutPiProvider === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    await services.auth.logoutPiProvider(piProvider.providerId!)
    writeJson(response, 204, undefined)
    return true
  }

  const piFlowAnswer = matchRouteParams(url.pathname, "/v1/harnesses/pi/auth-flows/:flowId/answer")
  if (piFlowAnswer !== undefined && request.method === "POST") {
    if (services.auth?.answerPiLogin === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    const payload = await readSchema(request, AnswerPiAuthRequestSchema)
    writeJson(response, 200, await services.auth.answerPiLogin(piFlowAnswer.flowId!, payload.value))
    return true
  }

  const piFlow = matchRouteParams(url.pathname, "/v1/harnesses/pi/auth-flows/:flowId")
  if (piFlow !== undefined) {
    if (request.method === "GET") {
      if (services.auth?.piLoginFlow === undefined)
        throw new HttpFailure(501, "Harness authentication unavailable")
      writeJson(response, 200, services.auth.piLoginFlow(piFlow.flowId!))
      return true
    }
    if (request.method === "DELETE") {
      if (services.auth?.cancelPiLogin === undefined)
        throw new HttpFailure(501, "Harness authentication unavailable")
      services.auth.cancelPiLogin(piFlow.flowId!)
      writeJson(response, 204, undefined)
      return true
    }
  }

  if (request.method === "POST" && url.pathname === "/v1/harnesses/auth/refresh") {
    if (services.auth === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    const harnessId = url.searchParams.get("harnessId")?.trim() || undefined
    await services.auth.refresh(harnessId)
    // Settings consumes this — keep lifecycle fields so a sign-in doesn't
    // wipe the row's update state.
    writeJson(
      response,
      200,
      await discoverHarnesses(services, harnessId === undefined, harnessId, true)
    )
    return true
  }

  const accountLoginAnswer = matchRouteParams(
    url.pathname,
    "/v1/harnesses/:id/accounts/:accountId/login/:flowId/answer"
  )
  if (accountLoginAnswer !== undefined && request.method === "POST") {
    if (services.auth === undefined) {
      throw new HttpFailure(501, "Harness authentication unavailable")
    }
    const payload = await readSchema(request, AnswerHarnessAuthRequestSchema)
    writeJson(
      response,
      200,
      await services.auth.answerLogin(accountLoginAnswer.flowId!, payload.code)
    )
    return true
  }

  const accountLoginCancel = matchRouteParams(
    url.pathname,
    "/v1/harnesses/:id/accounts/:accountId/login/:flowId"
  )
  if (accountLoginCancel !== undefined && request.method === "DELETE") {
    if (services.auth === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    await services.auth.cancelLogin(accountLoginCancel.flowId!)
    writeJson(response, 204, undefined)
    return true
  }

  const accountAction = matchRouteParams(
    url.pathname,
    "/v1/harnesses/:id/accounts/:accountId/:action"
  )
  if (accountAction !== undefined && request.method === "POST") {
    if (services.auth === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    const harnessId = accountAction.id!
    const accountId = accountAction.accountId!
    switch (accountAction.action) {
      case "activate":
        await services.auth.activateAccount(harnessId, accountId)
        writeJson(response, 200, await services.auth.accounts(harnessId))
        return true
      case "login": {
        const payload = await readSchema(request, StartHarnessLoginRequestSchema)
        writeJson(
          response,
          201,
          await services.auth.beginLogin(accountId, payload.methodId, payload.apiKey)
        )
        return true
      }
      case "logout":
        writeJson(response, 200, await services.auth.logout(accountId))
        return true
      default:
        break
    }
  }

  const accountProbe = matchRouteParams(
    url.pathname,
    "/v1/harnesses/:id/accounts/:accountId/auth/probe"
  )
  if (accountProbe !== undefined && request.method === "POST") {
    if (services.auth === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    writeJson(response, 200, await services.auth.probeAccount(accountProbe.accountId!, true))
    return true
  }

  const accountRoute = matchRouteParams(url.pathname, "/v1/harnesses/:id/accounts/:accountId")
  if (accountRoute !== undefined) {
    if (services.auth === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    if (request.method === "PATCH") {
      const payload = await readSchema(request, UpdateHarnessAccountRequestSchema)
      if (payload.label === undefined) throw new HttpFailure(400, "Account label is required")
      writeJson(
        response,
        200,
        await services.auth.renameAccount(accountRoute.accountId!, payload.label)
      )
      return true
    }
    if (request.method === "DELETE") {
      await services.auth.removeAccount(accountRoute.accountId!)
      writeJson(response, 204, undefined)
      return true
    }
  }

  const accountsHarnessId = matchRoute(url.pathname, "/v1/harnesses/:id/accounts")
  if (accountsHarnessId !== undefined) {
    if (services.auth === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    if (request.method === "GET") {
      writeJson(response, 200, await services.auth.accounts(accountsHarnessId))
      return true
    }
    if (request.method === "POST") {
      const payload = await readSchema(request, CreateHarnessAccountRequestSchema)
      writeJson(response, 201, await services.auth.createAccount(accountsHarnessId, payload.label))
      return true
    }
  }

  return false
}
