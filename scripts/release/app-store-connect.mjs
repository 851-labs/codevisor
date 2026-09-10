import { sign } from "node:crypto"
import { setTimeout } from "node:timers/promises"

export function appStoreToken({ privateKey, keyId, issuerId }, now = Date.now()) {
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url")
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
  constructor(method, path, status, details) {
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

export function appStoreClient(credentials, { fetchImplementation = fetch, now = Date.now } = {}) {
  return async (path, { query = {}, method = "GET", body, timeout = 60_000 } = {}) => {
    const url = new URL(`https://api.appstoreconnect.apple.com/v1/${path}`)
    url.search = new URLSearchParams(query).toString()
    const response = await fetchImplementation(url, {
      method,
      headers: {
        Authorization: `Bearer ${appStoreToken(credentials, now())}`,
        "Content-Type": "application/json"
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(Math.min(60_000, timeout))
    })
    if (!response.ok) {
      const details = await response.text()
      throw new AppStoreConnectError(method, path, response.status, details)
    }
    return response.status === 204 ? undefined : response.json()
  }
}

export async function findApp(client, bundleId) {
  const { data } = await client("apps", { query: { "filter[bundleId]": bundleId } })
  if (data.length !== 1) {
    throw new Error(
      `Expected one accessible App Store Connect app for ${bundleId}; found ${data.length}. Check the API key's team and app access.`
    )
  }
  return data[0]
}

export async function findBuild(client, { appId, version, buildNumber }) {
  const { data, included = [] } = await client("builds", {
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
  client,
  build,
  { attempts = 60, interval = 15_000, sleep = setTimeout } = {}
) {
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
    if (state === "VALID") {
      if (candidate.attributes.expired)
        throw new Error("The matching TestFlight build has expired.")
      if (candidate.attributes.buildAudienceType !== "INTERNAL_ONLY") {
        throw new Error("Refusing to distribute a build that is not marked INTERNAL_ONLY.")
      }
      if (
        ["PROCESSING_EXCEPTION", "EXPIRED", "MISSING_EXPORT_COMPLIANCE"].includes(internalState)
      ) {
        throw new Error(
          `iOS ${build.version} (${build.buildNumber}) cannot enter internal testing: ${internalState}. See TestFlight build details.`
        )
      }
      if (["READY_FOR_BETA_TESTING", "IN_BETA_TESTING"].includes(internalState)) return candidate
    }
    if (attempt + 1 < attempts) await sleep(interval)
  }
  throw new Error(
    `Timed out waiting for iOS ${build.version} (${build.buildNumber}) TestFlight readiness (${lastState}). Rerun the delivery job to resume.`
  )
}

export async function internalGroup(client, appId, name) {
  const { data } = await client("betaGroups", {
    query: { "filter[app]": appId, "filter[name]": name }
  })
  if (data.length > 1) throw new Error(`Multiple TestFlight groups are named ${name}.`)
  if (data.length === 1) {
    if (!data[0].attributes.isInternalGroup) {
      throw new Error(`TestFlight group ${name} is external; an internal group is required.`)
    }
    return data[0]
  }
  const created = await client("betaGroups", {
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

async function assignInternalBuild(
  client,
  build,
  group,
  {
    assignmentTimeout = 5 * 60_000,
    interval = 15_000,
    maxInterval = 60_000,
    sleep = setTimeout,
    now = () => performance.now()
  } = {}
) {
  const deadline = now() + assignmentTimeout
  const path = `betaGroups/${group.id}/relationships/builds`
  let lastError
  let accepted = false
  let delay = interval
  const timedOut = (cause = lastError) =>
    new Error(
      `Timed out assigning TestFlight build ${build.id} to ${group.attributes.name} (${group.id}); ` +
        `${accepted ? "assignment accepted, membership not visible" : "assignment not confirmed"}. ` +
        `Rerun the delivery job to resume.${cause ? ` Last error: ${cause.message}` : ""}`,
      { cause }
    )
  const request = async (requestPath, options) => {
    const remaining = deadline - now()
    if (remaining <= 0) throw timedOut()
    let result
    try {
      result = await client(requestPath, { ...options, timeout: Math.ceil(remaining) })
    } catch (error) {
      if (now() >= deadline) throw timedOut(error)
      throw error
    }
    if (now() >= deadline) throw timedOut()
    return result
  }
  const isAssigned = async () => {
    const { data } = await request("builds", {
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

export async function deliverInternalBuild(client, build, upload, options = {}) {
  // A retry may follow a successful upload whose processing outlasted the job.
  // Resume that build instead of uploading the same version/build number again.
  if (!(await findBuild(client, build))) await upload()
  const processed = await waitForBuild(client, build, options)
  const group = await internalGroup(client, build.appId, options.groupName ?? "Alpha")
  await assignInternalBuild(client, processed, group, options)
  return { build: processed, group }
}
