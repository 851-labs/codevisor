import { sign } from "node:crypto"
import { setTimeout } from "node:timers/promises"

export interface AppStoreCredentials {
  privateKey: string
  keyId: string
  issuerId: string
}

export interface AppStoreRequestOptions {
  query?: Record<string, string>
  method?: string
  body?: unknown
  timeout?: number
}

// Every caller declares the payload shape it reads: a decoded fetch body is
// only ever typed as unknown, and Apple's resources differ per collection.
export type AppStoreClient = <Result>(
  path: string,
  options?: AppStoreRequestOptions
) => Promise<Result>

export interface AppStoreClientOptions {
  fetchImplementation?: typeof fetch
  now?: () => number
}

export interface AppStoreErrorDetail {
  code?: string
  detail?: string
}

export interface ResourceIdentifier {
  type: string
  id: string
}

export interface AppAttributes {
  primaryLocale?: string
}

export interface AppResource {
  id: string
  type: string
  attributes: AppAttributes
}

export interface BuildAttributes {
  processingState: string
  buildAudienceType?: string
  expired?: boolean
}

export interface BuildBetaDetailAttributes {
  internalBuildState?: string
  externalBuildState?: string
  autoNotifyEnabled?: boolean
}

export interface BuildBetaDetailResource {
  id: string
  type: string
  attributes: BuildBetaDetailAttributes
}

export interface BuildResource {
  id: string
  type: string
  attributes: BuildAttributes
  relationships?: {
    buildBetaDetail?: { data?: ResourceIdentifier }
  }
}

// A build joined with the buildBetaDetail resource Apple side-loads beside it.
export interface ProcessedBuild extends BuildResource {
  betaDetail: BuildBetaDetailResource | undefined
}

export interface BuildListResponse {
  data: BuildResource[]
  included?: BuildBetaDetailResource[]
}

export interface BetaGroupAttributes {
  name?: string
  isInternalGroup?: boolean
  publicLink?: string | null
}

export interface BetaGroupResource {
  id: string
  type: string
  attributes: BetaGroupAttributes
}

// The coordinates that identify a single TestFlight build of one app.
export interface BuildQuery {
  appId: string
  version: string
  buildNumber: string
}

export interface WaitForBuildOptions {
  attempts?: number
  interval?: number
  sleep?: (milliseconds: number) => Promise<unknown>
}

export interface AssignBuildToGroupOptions {
  assignmentTimeout?: number
  interval?: number
  maxInterval?: number
  sleep?: (milliseconds: number) => Promise<unknown>
  now?: () => number
}

export interface DeliverInternalBuildOptions
  extends WaitForBuildOptions, AssignBuildToGroupOptions {
  groupName?: string
}

export interface DeliveredBuild {
  build: ProcessedBuild
  group: BetaGroupResource
}

export function appStoreToken(
  { privateKey, keyId, issuerId }: AppStoreCredentials,
  now = Date.now()
): string {
  const encode = (value: unknown) => Buffer.from(JSON.stringify(value)).toString("base64url")
  const issued = Math.floor(now / 1000)
  const header = encode({ alg: "ES256", kid: keyId, typ: "JWT" })
  const payload = encode({
    iss: issuerId,
    iat: issued,
    exp: issued + 1200,
    aud: "appstoreconnect-v1"
  })
  const message = `${header}.${payload}`
  const signature = sign("sha256", Buffer.from(message), {
    key: privateKey,
    dsaEncoding: "ieee-p1363"
  }).toString("base64url")
  return `${message}.${signature}`
}

export class AppStoreConnectError extends Error {
  method: string
  path: string
  status: number
  details: string
  errors: AppStoreErrorDetail[]

  constructor(method: string, path: string, status: number, details: string) {
    super(`App Store Connect ${method} ${path} failed (${status}): ${details}`)
    this.name = "AppStoreConnectError"
    this.method = method
    this.path = path
    this.status = status
    this.details = details
    this.errors = []
    try {
      const errors = JSON.parse(details)?.errors
      if (Array.isArray(errors)) this.errors = errors
    } catch {
      // Apple can return a non-JSON error body; retain it in the message.
    }
  }
}

export function appStoreClient(
  credentials: AppStoreCredentials,
  { fetchImplementation = fetch, now = Date.now }: AppStoreClientOptions = {}
): AppStoreClient {
  // The request itself can only produce unknown; the generic signature above is
  // the view each caller asks for, so the finished closure is asserted into it.
  return (async (
    path: string,
    { query = {}, method = "GET", body, timeout = 60_000 }: AppStoreRequestOptions = {}
  ): Promise<unknown> => {
    const url = new URL(`https://api.appstoreconnect.apple.com/v1/${path}`)
    url.search = new URLSearchParams(query).toString()
    // RequestInit declares body as an optional property rather than one that
    // accepts undefined, and a GET legitimately carries no body at all.
    const response = await fetchImplementation(url, {
      method,
      headers: {
        Authorization: `Bearer ${appStoreToken(credentials, now())}`,
        "Content-Type": "application/json"
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(Math.min(60_000, timeout))
    } as RequestInit)
    if (!response.ok) {
      const details = await response.text()
      throw new AppStoreConnectError(method, path, response.status, details)
    }
    return response.status === 204 ? undefined : response.json()
  }) as AppStoreClient
}

export async function findApp(client: AppStoreClient, bundleId: string): Promise<AppResource> {
  const { data } = await client<{ data: AppResource[] }>("apps", {
    query: { "filter[bundleId]": bundleId }
  })
  if (data.length !== 1) {
    throw new Error(
      `Expected one accessible App Store Connect app for ${bundleId}; found ${data.length}. Check the API key's team and app access.`
    )
  }
  // The length check above leaves exactly one app in the collection.
  return data[0]!
}

export async function findBuild(
  client: AppStoreClient,
  { appId, version, buildNumber }: BuildQuery
): Promise<ProcessedBuild | undefined> {
  const { data, included = [] } = await client<BuildListResponse>("builds", {
    query: {
      "filter[app]": appId,
      "filter[version]": buildNumber,
      "filter[preReleaseVersion.version]": version,
      "filter[preReleaseVersion.platform]": "IOS",
      include: "buildBetaDetail"
    }
  })
  if (data.length > 1) throw new Error("Multiple builds matched the iOS version and build number.")
  const candidate = data[0]
  if (!candidate) return undefined
  const detail = candidate.relationships?.buildBetaDetail?.data
  return {
    ...candidate,
    betaDetail: included.find(
      (resource) => resource.type === detail?.type && resource.id === detail?.id
    )
  }
}

export async function waitForBuild(
  client: AppStoreClient,
  build: BuildQuery,
  { attempts = 60, interval = 15_000, sleep = setTimeout }: WaitForBuildOptions = {}
): Promise<ProcessedBuild> {
  let lastState = "build not found"
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const candidate = await findBuild(client, build)
    const state = candidate?.attributes.processingState
    const internalState = candidate?.betaDetail?.attributes.internalBuildState
    lastState = `processing=${state ?? "not found"}, internal=${internalState ?? "not available"}`
    if (state === "FAILED" || state === "INVALID") {
      throw new Error(
        `Apple rejected iOS ${build.version} (${build.buildNumber}): ${state}. See TestFlight build details.`
      )
    }
    // Only a candidate can report a state; the second test restates that for
    // the type checker, which does not follow the optional chain above.
    if (state === "VALID" && candidate) {
      if (candidate.attributes.expired)
        throw new Error("The matching TestFlight build has expired.")
      if (candidate.attributes.buildAudienceType !== "APP_STORE_ELIGIBLE") {
        throw new Error("Expected an APP_STORE_ELIGIBLE build for later release promotion.")
      }
      if (
        (
          ["PROCESSING_EXCEPTION", "EXPIRED", "MISSING_EXPORT_COMPLIANCE"] as OptionalStates
        ).includes(internalState)
      ) {
        throw new Error(
          `iOS ${build.version} (${build.buildNumber}) cannot enter internal testing: ${internalState}. See TestFlight build details.`
        )
      }
      if ((["READY_FOR_BETA_TESTING", "IN_BETA_TESTING"] as OptionalStates).includes(internalState))
        return candidate
    }
    if (attempt + 1 < attempts) await sleep(interval)
  }
  throw new Error(
    `Timed out waiting for iOS ${build.version} (${build.buildNumber}) TestFlight readiness (${lastState}). Rerun the delivery job to resume.`
  )
}

// Apple omits a state entirely until it applies, so the literal state lists are
// widened before an optional value is looked up in them.
type OptionalStates = readonly (string | undefined)[]

export async function internalGroup(
  client: AppStoreClient,
  appId: string,
  name: string
): Promise<BetaGroupResource> {
  const { data } = await client<{ data: BetaGroupResource[] }>("betaGroups", {
    query: { "filter[app]": appId, "filter[name]": name }
  })
  if (data.length > 1) throw new Error(`Multiple TestFlight groups are named ${name}.`)
  // The length checks bracket the collection to exactly one group here.
  if (data.length === 1) {
    if (!data[0]!.attributes.isInternalGroup) {
      throw new Error(`TestFlight group ${name} is external; an internal group is required.`)
    }
    return data[0]!
  }
  const created = await client<{ data: BetaGroupResource }>("betaGroups", {
    method: "POST",
    body: {
      data: {
        type: "betaGroups",
        attributes: {
          name,
          isInternalGroup: true,
          hasAccessToAllBuilds: false,
          publicLinkEnabled: false
        },
        relationships: { app: { data: { type: "apps", id: appId } } }
      }
    }
  })
  return created.data
}

export async function assignBuildToGroup(
  client: AppStoreClient,
  build: BuildResource,
  group: BetaGroupResource,
  {
    assignmentTimeout = 5 * 60_000,
    interval = 15_000,
    maxInterval = 60_000,
    sleep = setTimeout,
    now = () => performance.now()
  }: AssignBuildToGroupOptions = {}
): Promise<void> {
  const deadline = now() + assignmentTimeout
  const path = `betaGroups/${group.id}/relationships/builds`
  let lastError: Error | undefined
  let accepted = false
  let delay = interval
  const timedOut = (cause: Error | undefined = lastError) =>
    new Error(
      `Timed out assigning TestFlight build ${build.id} to ${group.attributes.name} (${group.id}); ` +
        `${accepted ? "assignment accepted, membership not visible" : "assignment not confirmed"}. ` +
        `Rerun the delivery job to resume.${cause ? ` Last error: ${cause.message}` : ""}`,
      { cause }
    )
  const request = async <Result>(
    requestPath: string,
    options: AppStoreRequestOptions
  ): Promise<Result> => {
    const remaining = deadline - now()
    if (remaining <= 0) throw timedOut()
    let result: Result
    try {
      result = await client<Result>(requestPath, { ...options, timeout: Math.ceil(remaining) })
    } catch (error) {
      // Only the App Store client rejects here, and it always rejects with an Error.
      if (now() >= deadline) throw timedOut(error as Error)
      throw error
    }
    if (now() >= deadline) throw timedOut()
    return result
  }
  const isAssigned = async () => {
    const { data } = await request<{ data: ResourceIdentifier[] }>("builds", {
      query: { "filter[id]": build.id, "filter[betaGroups]": group.id, limit: "1" }
    })
    return data.some((candidate) => candidate.type === "builds" && candidate.id === build.id)
  }

  while (now() < deadline) {
    if (await isAssigned()) return
    if (!accepted) {
      try {
        await request(path, {
          method: "POST",
          body: { data: [{ type: "builds", id: build.id }] }
        })
        accepted = true
      } catch (error) {
        // A newly processed build may not yet be visible to the assignment endpoint.
        // Retry only Apple's NOT_FOUND response naming this exact build.
        if (
          !(error instanceof AppStoreConnectError) ||
          error.status !== 404 ||
          error.method !== "POST" ||
          error.path !== path ||
          error.errors.length === 0 ||
          !error.errors.every(
            (detail) =>
              detail?.code === "NOT_FOUND" &&
              detail.detail === `There is no resource of type 'builds' with id '${build.id}'`
          )
        ) {
          throw error
        }
        lastError = error
      }
      if (accepted && (await isAssigned())) return
    }
    const remaining = deadline - now()
    if (remaining <= 0) break
    await sleep(Math.min(delay, remaining))
    delay = Math.min(delay * 2, maxInterval)
  }
  throw timedOut()
}

export async function deliverInternalBuild(
  client: AppStoreClient,
  build: BuildQuery,
  upload: () => Promise<unknown>,
  options: DeliverInternalBuildOptions = {}
): Promise<DeliveredBuild> {
  // A retry may follow a successful upload whose processing outlasted the job.
  // Resume that build instead of uploading the same version/build number again.
  if (!(await findBuild(client, build))) await upload()
  const processed = await waitForBuild(client, build, options)
  const group = await internalGroup(client, build.appId, options.groupName ?? "Alpha")
  await assignBuildToGroup(client, processed, group, options)
  return { build: processed, group }
}
