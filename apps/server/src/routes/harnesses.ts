import type { Harness, HarnessCapability } from "@codevisor/api"
import {
  AnswerOpenCodeAuthRequest as AnswerOpenCodeAuthRequestSchema,
  AnswerPiAuthRequest as AnswerPiAuthRequestSchema,
  CreateHarnessAccountRequest as CreateHarnessAccountRequestSchema,
  StartHarnessLoginRequest as StartHarnessLoginRequestSchema,
  StartOpenCodeAuthRequest as StartOpenCodeAuthRequestSchema,
  StartPiAuthRequest as StartPiAuthRequestSchema,
  UpdateHarnessAccountRequest as UpdateHarnessAccountRequestSchema,
  UpdateHarnessRequest as UpdateHarnessRequestSchema
} from "@codevisor/api"
import type { IncomingMessage, ServerResponse } from "node:http"
import { tmpdir } from "node:os"
import { parseCustomHarnessDocument } from "@codevisor/harness-manager"
import {
  existingDirectory,
  HttpFailure,
  matchRoute,
  matchRouteParams,
  readJson,
  readSchema,
  run,
  swallowError,
  writeJson,
  type CodevisorServerServices
} from "../server-context.js"

export const routeHarnesses = async (
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

  if (request.method === "GET" && url.pathname === "/v1/harnesses") {
    const includeLifecycle = url.searchParams.get("include") === "lifecycle"
    writeJson(response, 200, await discoverHarnesses(services, false, undefined, includeLifecycle))
    return true
  }

  // Re-resolves the runtime's PATH (login-shell probe) before re-detecting,
  // so a CLI installed after server start is found without a restart.
  if (request.method === "POST" && url.pathname === "/v1/harnesses/rescan") {
    await run(services.agents.refreshEnvironment)
    writeJson(response, 200, await discoverHarnesses(services, true, undefined, true))
    return true
  }

  // Forced latest-version check for every installed harness, then the
  // refreshed list (blocking rescan pattern — checks are cheap fetches).
  if (request.method === "POST" && url.pathname === "/v1/harnesses/check-updates") {
    if (services.lifecycle === undefined)
      throw new HttpFailure(501, "Harness update checks unavailable")
    await services.lifecycle.checkForUpdates(true)
    writeJson(response, 200, await discoverHarnesses(services, false, undefined, true))
    return true
  }

  // One-click install: 202-ack, work runs in the background, progress via
  // harness.lifecycle.updated events + the attachable output terminal.
  const installHarnessId = matchRoute(url.pathname, "/v1/harnesses/:id/install")
  if (installHarnessId !== undefined && request.method === "POST") {
    if (services.lifecycle === undefined) throw new HttpFailure(501, "Harness install unavailable")
    const body = (await readJson(request)) as { readonly methodId?: string }
    const methodId = typeof body.methodId === "string" ? body.methodId : undefined
    try {
      const { terminalId } = await services.lifecycle.beginInstall(installHarnessId, methodId)
      writeJson(response, 202, { accepted: true, terminalId })
    } catch (cause) {
      throw conflictFrom(cause)
    }
    return true
  }

  // Dual-install: the bundled desktop app's version/update state, computed
  // on demand (detail sheet), and its explicit update action.
  const bundledAppHarnessId = matchRoute(url.pathname, "/v1/harnesses/:id/bundled-app")
  if (bundledAppHarnessId !== undefined && request.method === "GET") {
    if (services.lifecycle === undefined)
      throw new HttpFailure(501, "Harness update checks unavailable")
    const info = await services.lifecycle.bundledAppInfo(bundledAppHarnessId).catch(swallowError)
    if (info === undefined) throw new HttpFailure(404, "No bundled desktop app")
    writeJson(response, 200, info)
    return true
  }
  const bundledAppUpdateHarnessId = matchRoute(url.pathname, "/v1/harnesses/:id/bundled-app/update")
  if (bundledAppUpdateHarnessId !== undefined && request.method === "POST") {
    if (services.lifecycle === undefined)
      throw new HttpFailure(501, "Harness update checks unavailable")
    try {
      await services.lifecycle.beginBundledAppUpdate(bundledAppUpdateHarnessId)
      writeJson(response, 202, { accepted: true })
    } catch (cause) {
      throw conflictFrom(cause)
    }
    return true
  }

  // Pending-update controls: "Update Now" skips the idle wait; DELETE
  // disarms a queued update entirely.
  const pendingApplyHarnessId = matchRoute(url.pathname, "/v1/harnesses/:id/update/pending/apply")
  if (pendingApplyHarnessId !== undefined && request.method === "POST") {
    if (services.lifecycle === undefined) throw new HttpFailure(501, "Harness update unavailable")
    try {
      await services.lifecycle.forcePendingUpdate(pendingApplyHarnessId)
      writeJson(response, 202, { accepted: true })
    } catch (cause) {
      throw conflictFrom(cause)
    }
    return true
  }
  const pendingCancelHarnessId = matchRoute(url.pathname, "/v1/harnesses/:id/update/pending")
  if (pendingCancelHarnessId !== undefined && request.method === "DELETE") {
    if (services.lifecycle === undefined) throw new HttpFailure(501, "Harness update unavailable")
    try {
      await services.lifecycle.cancelPendingUpdate(pendingCancelHarnessId)
      writeJson(response, 204, undefined)
    } catch (cause) {
      throw conflictFrom(cause)
    }
    return true
  }

  // One-click update for CLI harnesses (origin-matched vendor flow).
  const updateHarnessId = matchRoute(url.pathname, "/v1/harnesses/:id/update")
  if (updateHarnessId !== undefined && request.method === "POST") {
    if (services.lifecycle === undefined) throw new HttpFailure(501, "Harness update unavailable")
    try {
      const outcome = await services.lifecycle.beginUpdate(updateHarnessId)
      writeJson(response, 202, { accepted: true, ...outcome })
    } catch (cause) {
      throw conflictFrom(cause)
    }
    return true
  }

  // User-defined custom ACP harnesses (~/.codevisor/harnesses.json).
  if (
    url.pathname === "/v1/harnesses/custom" &&
    (request.method === "GET" || request.method === "PUT")
  ) {
    if (services.customHarnesses === undefined)
      throw new HttpFailure(501, "Custom harnesses unavailable")
    if (request.method === "GET") {
      writeJson(response, 200, { harnesses: await services.customHarnesses.list() })
      return true
    }
    // Whole-list replace: the file is the source of truth and stays
    // hand-editable, so the API rewrites it rather than patching entries.
    {
      const body = await readJson(request)
      const parsed = parseCustomHarnessDocument(body, "request body")
      if (parsed.warnings.length > 0) {
        // Reject instead of skipping: the API must never persist entries the
        // next boot would drop.
        throw new HttpFailure(400, parsed.warnings.join("; "))
      }
      await services.customHarnesses.replace(parsed.specs)
      writeJson(response, 200, await discoverHarnesses(services, true, undefined, true))
      return true
    }
  }

  // One-shot ACP initialize handshake for a (possibly unsaved) custom spec —
  // the "Test Connection" action. Blocking with the store's own timeout.
  if (request.method === "POST" && url.pathname === "/v1/harnesses/custom/test") {
    if (services.customHarnesses === undefined)
      throw new HttpFailure(501, "Custom harnesses unavailable")
    const body = await readJson(request)
    const parsed = parseCustomHarnessDocument([body], "request body")
    const spec = parsed.specs[0]
    if (spec === undefined) {
      /* v8 ignore next -- the single-entry wrapper always yields a warning when the spec is invalid. */
      throw new HttpFailure(400, parsed.warnings.join("; ") || "Invalid custom harness spec")
    }
    writeJson(response, 200, await services.customHarnesses.test(spec))
    return true
  }

  // Sessions from the harness's own on-disk store (run before/outside
  // Codevisor) — onboarding workspace suggestions and chat import read these,
  // NOT Codevisor's sessions table (empty on a fresh install by definition).
  const agentSessionsHarnessId = matchRoute(url.pathname, "/v1/harnesses/:id/agent-sessions")
  if (agentSessionsHarnessId !== undefined && request.method === "GET") {
    const account = await services.auth?.activeAccountContext(agentSessionsHarnessId)
    writeJson(
      response,
      200,
      await run(services.agents.listAgentSessions(agentSessionsHarnessId, account))
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

  const harnessId = matchRoute(url.pathname, "/v1/harnesses/:id")
  if (harnessId !== undefined && request.method === "PATCH") {
    const payload = await readSchema(request, UpdateHarnessRequestSchema)
    if (payload.enabled && services.auth !== undefined) {
      const candidate = (await discoverHarnesses(services, true)).find(
        (harness) => harness.id === harnessId
      )
      const state = candidate?.auth?.state
      if (state !== "authenticated" && state !== "notRequired") {
        throw new HttpFailure(409, "Sign in before enabling this harness")
      }
    }
    await run(services.db.setHarnessEnabled(harnessId, payload.enabled))
    const harness = (await discoverHarnesses(services)).find(
      (candidate) => candidate.id === harnessId
    )
    if (harness === undefined) {
      throw new HttpFailure(404, `Harness not found: ${harnessId}`)
    }
    writeJson(response, 200, harness)
    return true
  }

  return false
}

export const discoverCapabilities = async (
  services: CodevisorServerServices,
  url: URL
): Promise<{ readonly harnesses: ReadonlyArray<HarnessCapability> }> => {
  const cwd = existingDirectory(url.searchParams.get("cwd")) ?? tmpdir()
  // Existing chats already know their harness. Filtering before auth
  // decoration and inspection is important: both stages can start real CLI
  // processes, so inspecting the whole catalog would put unrelated agents on
  // the resumed chat's critical path.
  const requestedHarnessId = url.searchParams.get("harnessId")?.trim() || undefined
  const requestedConfigSelections = Object.fromEntries(
    [...url.searchParams.entries()].flatMap(([key, value]) =>
      key.startsWith("config.") && key.length > "config.".length
        ? [[key.slice("config.".length), value] as const]
        : []
    )
  )
  const harnesses = await discoverHarnesses(services, false, requestedHarnessId)
  const readyHarnesses = harnesses.filter(
    (harness) => harness.enabled && harness.readiness.state === "ready"
  )
  return {
    harnesses: await Promise.all(
      readyHarnesses.map(async (harness) => {
        try {
          const account = await services.auth?.activeAccountContext(harness.id)
          const metadata = await run(
            services.agents.inspectHarness(
              harness.id,
              cwd,
              account,
              requestedHarnessId === harness.id ? requestedConfigSelections : undefined
            )
          )
          return {
            harness,
            ...(metadata.modes === undefined ? {} : { modes: metadata.modes }),
            configOptions: metadata.configOptions,
            ...(metadata.supportsGoals === undefined
              ? {}
              : { supportsGoals: metadata.supportsGoals })
          }
        } catch {
          return {
            harness,
            configOptions: []
          }
        }
      })
    )
  }
}

/// Lifecycle route failures surface as conflicts with the manager's reason.
const conflictFrom = (cause: unknown): HttpFailure =>
  new HttpFailure(409, cause instanceof Error ? cause.message : String(cause))

export const discoverHarnesses = async (
  services: CodevisorServerServices,
  forceAuth = false,
  harnessId?: string,
  /// Lifecycle decoration (update knowledge, install methods) rides only on
  /// requests that render it — Settings, rescans, update checks. The plain
  /// list stays as light as possible for the composer's harness picker.
  includeLifecycle = false
): Promise<ReadonlyArray<Harness>> => {
  const discovered = await run(
    services.db.applyHarnessSettings(await run(services.agents.discoverHarnesses))
  )
  const filtered =
    harnessId === undefined ? discovered : discovered.filter((harness) => harness.id === harnessId)
  const harnesses =
    includeLifecycle && services.lifecycle !== undefined
      ? await services.lifecycle.decorateHarnesses(filtered)
      : filtered
  return services.auth === undefined
    ? harnesses
    : services.auth.decorateHarnesses(harnesses, forceAuth)
}
