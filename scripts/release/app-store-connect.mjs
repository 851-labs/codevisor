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

export function appStoreClient(credentials, { fetchImplementation = fetch, now = Date.now } = {}) {
  return async (path, { query = {}, method = "GET", body } = {}) => {
    const url = new URL(`https://api.appstoreconnect.apple.com/v1/${path}`)
    url.search = new URLSearchParams(query).toString()
    const response = await fetchImplementation(url, {
      method,
      headers: {
        Authorization: `Bearer ${appStoreToken(credentials, now())}`,
        "Content-Type": "application/json"
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(60_000)
    })
    if (!response.ok) {
      const details = await response.text()
      throw new Error(`App Store Connect ${method} ${path} failed (${response.status}): ${details}`)
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
  const { data } = await client("builds", {
    query: {
      "filter[app]": appId,
      "filter[version]": buildNumber,
      "filter[preReleaseVersion.version]": version,
      "filter[preReleaseVersion.platform]": "IOS",
      include: "buildBetaDetail"
    }
  })
  if (data.length > 1) throw new Error("Multiple builds matched the iOS version and build number.")
  return data[0]
}

export async function waitForBuild(
  client,
  build,
  { attempts = 60, interval = 15_000, sleep = setTimeout } = {}
) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const candidate = await findBuild(client, build)
    const state = candidate?.attributes.processingState
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
      return candidate
    }
    if (attempt + 1 < attempts) await sleep(interval)
  }
  throw new Error(
    `Timed out waiting for iOS ${build.version} (${build.buildNumber}) processing. Rerun the delivery job to resume.`
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

export async function deliverInternalBuild(client, build, upload, options = {}) {
  // A retry may follow a successful upload whose processing outlasted the job.
  // Resume that build instead of uploading the same version/build number again.
  if (!(await findBuild(client, build))) await upload()
  const processed = await waitForBuild(client, build, options)
  const group = await internalGroup(client, build.appId, options.groupName ?? "Alpha")
  await client(`betaGroups/${group.id}/relationships/builds`, {
    method: "POST",
    body: { data: [{ type: "builds", id: processed.id }] }
  })
  return { build: processed, group }
}
