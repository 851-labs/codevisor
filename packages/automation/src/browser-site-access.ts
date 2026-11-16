import { waitForReady, type BrowserRuntime, type PageHandle } from "./browser-cdp-engine.js"
import { isPlainRecord, recordOrUndefined } from "./unknown-values.js"

type CdpParams = Readonly<Record<string, unknown>>

export const grantSiteAccess = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  url: string,
  args: CdpParams
): Promise<void> => {
  const credentials = httpCredentials(args.httpCredentials)
  const trustCertificate = args.ignoreCertificateErrors === true
  if (credentials === undefined && !trustCertificate) return

  const site = siteOf(url)
  const access = accessFor(runtime, page.sessionId)
  if (credentials !== undefined) {
    access.credentials.set(site.origin, credentials)
    await answerAuthChallenges(runtime, page, access)
  }
  if (trustCertificate) {
    access.untrustedHosts.add(site.host)
    await answerCertificateErrors(runtime, page)
  }
}

export const observeSiteAccessEvent = (
  runtime: BrowserRuntime,
  method: string,
  params: CdpParams,
  sessionId: string | undefined
): void => {
  if (method === "Target.detachedFromTarget") forgetAccess(runtime, params.sessionId)
  if (sessionId === undefined) return

  const access = granted.get(runtime)?.get(sessionId)
  if (access === undefined) return
  const answer = answers[method]?.(access, params)
  if (answer === undefined) return
  void runtime.connection.send(answer.method, answer.params, sessionId).catch(() => undefined)
}

export const navigationFailure = (
  runtime: BrowserRuntime,
  page: PageHandle,
  url: string,
  errorText: string
): Error => {
  const refused = granted.get(runtime)?.get(page.sessionId)?.refusedCertificates.get(url)
  return blockedSite(refused === undefined ? errorText : `net::${refused}`)
}

const blockedSite = (errorText: string): Error => {
  if (errorText === "net::ERR_INVALID_AUTH_CREDENTIALS")
    return new Error(
      `This page asks for a username and password (HTTP authentication) and none were accepted (${errorText}). Get them from the user, then open it with tab.goto(url, { httpCredentials: { username, password } }).`
    )
  if (errorText.startsWith("net::ERR_CERT_"))
    return new Error(
      `The site's certificate isn't trusted (${errorText}), so the browser stopped. If the user expects that, as with a local or staging server, open it with tab.goto(url, { ignoreCertificateErrors: true }); that trusts this one host in this tab.`
    )
  return new Error(errorText)
}

interface HttpCredentials {
  readonly username: string
  readonly password: string
}

interface SiteAccess {
  readonly credentials: Map<string, HttpCredentials>
  readonly untrustedHosts: Set<string>
  readonly answeredChallenges: Set<string>
  readonly refusedCertificates: Map<string, string>
}

interface CdpCommand {
  readonly method: string
  readonly params: CdpParams
}

const granted = new WeakMap<BrowserRuntime, Map<string, SiteAccess>>()

const accessFor = (runtime: BrowserRuntime, sessionId: string): SiteAccess => {
  let sessions = granted.get(runtime)
  if (sessions === undefined) {
    sessions = new Map()
    granted.set(runtime, sessions)
  }
  let access = sessions.get(sessionId)
  if (access === undefined) {
    access = {
      credentials: new Map(),
      untrustedHosts: new Set(),
      answeredChallenges: new Set(),
      refusedCertificates: new Map()
    }
    sessions.set(sessionId, access)
  }
  return access
}

const forgetAccess = (runtime: BrowserRuntime, sessionId: unknown): void => {
  if (typeof sessionId === "string") granted.get(runtime)?.delete(sessionId)
}

const httpCredentials = (value: unknown): HttpCredentials | undefined => {
  if (value === undefined || value === null) return undefined
  if (
    !isPlainRecord(value) ||
    typeof value.username !== "string" ||
    typeof value.password !== "string"
  )
    throw new Error("httpCredentials must be { username, password }")
  return { username: value.username, password: value.password }
}

const siteOf = (url: string): URL => {
  if (!URL.canParse(url))
    throw new Error("httpCredentials and ignoreCertificateErrors need a full URL to apply to")
  return new URL(url)
}

const answerAuthChallenges = (
  runtime: BrowserRuntime,
  page: PageHandle,
  access: SiteAccess
): Promise<unknown> =>
  runtime.connection.send(
    "Fetch.enable",
    {
      handleAuthRequests: true,
      patterns: [...access.credentials.keys()].map((origin) => ({ urlPattern: `${origin}/*` }))
    },
    page.sessionId
  )

const answerCertificateErrors = async (
  runtime: BrowserRuntime,
  page: PageHandle
): Promise<void> => {
  const enabled = await enableSecurity(runtime, page)
  if (!enabled) {
    await runtime.connection.send("Page.navigate", { url: "about:blank" }, page.sessionId)
    await waitForReady(runtime, page)
    await runtime.connection.send("Security.enable", {}, page.sessionId)
  }
  await runtime.connection.send(
    "Security.setOverrideCertificateErrors",
    { override: true },
    page.sessionId
  )
}

const enableSecurity = (runtime: BrowserRuntime, page: PageHandle): Promise<boolean> =>
  runtime.connection.send("Security.enable", {}, page.sessionId).then(
    () => true,
    () => false
  )

const continuePausedRequest = (_access: SiteAccess, params: CdpParams): CdpCommand => ({
  method: "Fetch.continueRequest",
  params: { requestId: params.requestId }
})

const answerAuthChallenge = (access: SiteAccess, params: CdpParams): CdpCommand => ({
  method: "Fetch.continueWithAuth",
  params: { requestId: params.requestId, authChallengeResponse: challengeResponse(access, params) }
})

const challengeResponse = (access: SiteAccess, params: CdpParams): CdpParams => {
  const requestId = String(params.requestId)
  const challenge = recordOrUndefined(params.authChallenge)
  const credentials = access.credentials.get(String(challenge?.origin))
  const firstAttempt = !access.answeredChallenges.has(requestId)
  if (credentials === undefined || challenge?.source === "Proxy" || !firstAttempt)
    return { response: "Default" }

  access.answeredChallenges.add(requestId)
  return { response: "ProvideCredentials", ...credentials }
}

const answerCertificateError = (access: SiteAccess, params: CdpParams): CdpCommand => {
  const action = certificateAction(access, params.requestURL)
  if (action === "cancel")
    access.refusedCertificates.set(String(params.requestURL), String(params.errorType))
  return { method: "Security.handleCertificateError", params: { eventId: params.eventId, action } }
}

const certificateAction = (access: SiteAccess, requestUrl: unknown): "continue" | "cancel" => {
  if (typeof requestUrl !== "string" || !URL.canParse(requestUrl)) return "cancel"
  return access.untrustedHosts.has(new URL(requestUrl).host) ? "continue" : "cancel"
}

const answers: Readonly<
  Record<string, ((access: SiteAccess, params: CdpParams) => CdpCommand) | undefined>
> = {
  "Fetch.requestPaused": continuePausedRequest,
  "Fetch.authRequired": answerAuthChallenge,
  "Security.certificateError": answerCertificateError
}
