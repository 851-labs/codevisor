import { waitForReady, type BrowserRuntime, type PageHandle } from "./browser-cdp-engine.js"
import { isPlainRecord, recordOrUndefined } from "./unknown-values.js"

type CdpParams = Readonly<Record<string, unknown>>

export interface SiteVisit {
  readonly failure: (errorText: string | undefined) => Error | undefined
  readonly end: () => Promise<void>
}

export const beginSiteVisit = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  url: string,
  args: CdpParams
): Promise<SiteVisit> => {
  const credentials = httpCredentials(args.httpCredentials)
  const trustCertificate = args.ignoreCertificateErrors === true
  const site = siteOf(url, credentials !== undefined || trustCertificate)
  if (site === undefined) return unwatchedVisit

  const access = accessFor(runtime, page.sessionId)
  access.refusedLogin = false
  access.refusedCertificate = undefined
  access.visiting = site.origin
  if (credentials !== undefined) access.credentials.set(site.origin, credentials)
  if (trustCertificate) access.untrustedHosts.add(site.host)

  await answerAuthChallenges(runtime, page, access)
  if (trustCertificate) await answerCertificateErrors(runtime, page)
  return {
    failure: (errorText) => visitFailure(access, errorText),
    end: () => endVisit(runtime, page, access)
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

interface HttpCredentials {
  readonly username: string
  readonly password: string
}

interface SiteAccess {
  readonly credentials: Map<string, HttpCredentials>
  readonly untrustedHosts: Set<string>
  readonly answeredChallenges: Set<string>
  visiting: string | undefined
  intercepting: boolean
  refusedLogin: boolean
  refusedCertificate: string | undefined
}

interface CdpCommand {
  readonly method: string
  readonly params: CdpParams
}

const granted = new WeakMap<BrowserRuntime, Map<string, SiteAccess>>()

const unwatchedVisit: SiteVisit = {
  failure: (errorText) => (errorText === undefined ? undefined : new Error(errorText)),
  end: async () => {}
}

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
      visiting: undefined,
      intercepting: false,
      refusedLogin: false,
      refusedCertificate: undefined
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

const siteOf = (url: string, required: boolean): URL | undefined => {
  const site = URL.canParse(url) ? new URL(url) : undefined
  if (site?.protocol === "http:" || site?.protocol === "https:") return site
  if (required)
    throw new Error("httpCredentials and ignoreCertificateErrors need a full http(s) URL")
  return undefined
}

const visitFailure = (access: SiteAccess, errorText: string | undefined): Error | undefined => {
  if (access.refusedLogin) return blockedSite("net::ERR_INVALID_AUTH_CREDENTIALS")
  if (errorText === undefined) return undefined
  if (access.refusedCertificate !== undefined)
    return blockedSite(`net::${access.refusedCertificate}`)
  return blockedSite(errorText)
}

const endVisit = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  access: SiteAccess
): Promise<void> => {
  access.visiting = undefined
  await answerAuthChallenges(runtime, page, access).catch(() => undefined)
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

const answerAuthChallenges = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  access: SiteAccess
): Promise<void> => {
  const origins = new Set(access.credentials.keys())
  if (access.visiting !== undefined) origins.add(access.visiting)
  if (origins.size === 0 && !access.intercepting) return

  access.intercepting = origins.size > 0
  if (!access.intercepting) {
    await runtime.connection.send("Fetch.disable", {}, page.sessionId)
    return
  }
  await runtime.connection.send(
    "Fetch.enable",
    {
      handleAuthRequests: true,
      patterns: [...origins].map((origin) => ({
        urlPattern: `${origin}/*`,
        resourceType: "Document"
      }))
    },
    page.sessionId
  )
}

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
  if (challenge?.source === "Proxy") return { response: "Default" }

  const credentials = access.credentials.get(String(challenge?.origin))
  if (credentials === undefined || access.answeredChallenges.has(requestId)) {
    access.refusedLogin = true
    return { response: "CancelAuth" }
  }
  access.answeredChallenges.add(requestId)
  return { response: "ProvideCredentials", ...credentials }
}

const answerCertificateError = (access: SiteAccess, params: CdpParams): CdpCommand => {
  const action = certificateAction(access, params.requestURL)
  if (action === "cancel") access.refusedCertificate = String(params.errorType)
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
