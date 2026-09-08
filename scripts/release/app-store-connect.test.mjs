import assert from "node:assert/strict"
import { createPublicKey, verify } from "node:crypto"
import test from "node:test"

import {
  appStoreClient,
  appStoreToken,
  deliverInternalBuild,
  findApp,
  internalGroup,
  waitForBuild
} from "./app-store-connect.mjs"

// Public test fixture. This key has never been registered with Apple.
const privateKey = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgzCncWVIrLZn98Skm
aMBqCDEJbkF+dDR7f8xgXFr4k6uhRANCAARsJMG/JX/pUF7QgVsxX30DiMyEtw3r
HFugpyUpdCsX+Z3SrfPyq7+v21XbnOeDnUjdMNXtTJ4cd++x1lbBQLKn
-----END PRIVATE KEY-----`
const credentials = { privateKey, keyId: "EXAMPLEKEY", issuerId: "example-issuer" }
const build = { appId: "app", version: "1.2.3", buildNumber: "42" }
const validBuild = {
  id: "build",
  type: "builds",
  attributes: { processingState: "VALID", buildAudienceType: "INTERNAL_ONLY", expired: false }
}
const group = {
  id: "group",
  type: "betaGroups",
  attributes: { name: "Alpha", isInternalGroup: true }
}

test("API authentication creates an ES256 token with Apple's audience and a bounded lifetime", () => {
  const token = appStoreToken(credentials, 1_700_000_000_000)
  const [header, payload, signature] = token.split(".")
  const decode = (value) => JSON.parse(Buffer.from(value, "base64url"))
  assert.deepEqual(decode(header), { alg: "ES256", kid: "EXAMPLEKEY", typ: "JWT" })
  assert.deepEqual(decode(payload), {
    iss: "example-issuer",
    iat: 1_700_000_000,
    exp: 1_700_001_200,
    aud: "appstoreconnect-v1"
  })
  assert.equal(
    verify(
      "sha256",
      Buffer.from(`${header}.${payload}`),
      {
        key: createPublicKey(privateKey),
        dsaEncoding: "ieee-p1363"
      },
      Buffer.from(signature, "base64url")
    ),
    true
  )
})

test("app preflight queries the exact bundle and exposes authorization failures", async () => {
  const client = appStoreClient(credentials, {
    now: () => 1_700_000_000_000,
    fetchImplementation: async (url, options) => {
      assert.equal(url.origin, "https://api.appstoreconnect.apple.com")
      assert.equal(url.searchParams.get("filter[bundleId]"), "com.example.app")
      assert.match(options.headers.Authorization, /^Bearer /)
      return new Response("API key lacks access", { status: 403 })
    }
  })
  await assert.rejects(findApp(client, "com.example.app"), /403.*API key lacks access/)
  await assert.rejects(
    findApp(async () => ({ data: [] }), "com.example.app"),
    /team and app access/
  )
})

test("processing waits for an absent build to appear and become valid", async () => {
  const states = [undefined, { attributes: { processingState: "PROCESSING" } }, validBuild]
  const delays = []
  const result = await waitForBuild(
    async (path, { query }) => {
      assert.equal(path, "builds")
      assert.equal(query["filter[app]"], "app")
      assert.equal(query["filter[version]"], "42")
      assert.equal(query["filter[preReleaseVersion.version]"], "1.2.3")
      assert.equal(query["filter[preReleaseVersion.platform]"], "IOS")
      const candidate = states.shift()
      return { data: candidate ? [candidate] : [] }
    },
    build,
    {
      attempts: 3,
      interval: 100,
      sleep: async (milliseconds) => {
        delays.push(milliseconds)
      }
    }
  )
  assert.equal(result.id, "build")
  assert.deepEqual(delays, [100, 100])
})

test("processing fails promptly on rejected, external-eligible, or expired builds", async () => {
  for (const [attributes, message] of [
    [{ processingState: "FAILED" }, /Apple rejected/],
    [{ processingState: "INVALID" }, /Apple rejected/],
    [{ processingState: "VALID", buildAudienceType: "APP_STORE_ELIGIBLE" }, /INTERNAL_ONLY/],
    [{ processingState: "VALID", expired: true }, /expired/]
  ]) {
    await assert.rejects(
      waitForBuild(async () => ({ data: [{ attributes }] }), build, {
        sleep: async () => assert.fail("Terminal states must not sleep")
      }),
      message
    )
  }
})

test("processing timeout is bounded without real timers", async () => {
  let requests = 0
  let sleeps = 0
  await assert.rejects(
    waitForBuild(
      async () => {
        requests += 1
        return { data: [] }
      },
      build,
      {
        attempts: 3,
        sleep: async () => {
          sleeps += 1
        }
      }
    ),
    /Timed out/
  )
  assert.equal(requests, 3)
  assert.equal(sleeps, 2)
})

test("delivery uploads once, creates an internal group, and assigns the processed build", async () => {
  const operations = []
  let uploaded = false
  const client = async (path, options = {}) => {
    operations.push([path, options.method ?? "GET"])
    if (path === "builds") return { data: uploaded ? [validBuild] : [] }
    if (path === "betaGroups" && options.method !== "POST") return { data: [] }
    if (path === "betaGroups") {
      assert.deepEqual(options.body.data.attributes, {
        name: "Alpha",
        isInternalGroup: true,
        hasAccessToAllBuilds: false,
        publicLinkEnabled: false
      })
      assert.equal(options.body.data.relationships.app.data.id, "app")
      return { data: group }
    }
    assert.equal(path, "betaGroups/group/relationships/builds")
    assert.deepEqual(options.body, { data: [{ type: "builds", id: "build" }] })
  }
  await deliverInternalBuild(client, build, async () => {
    operations.push(["upload", "POST"])
    uploaded = true
  })
  assert.deepEqual(operations, [
    ["builds", "GET"],
    ["upload", "POST"],
    ["builds", "GET"],
    ["betaGroups", "GET"],
    ["betaGroups", "POST"],
    ["betaGroups/group/relationships/builds", "POST"]
  ])
})

test("a delivery retry reuses an uploaded build and its existing internal group", async () => {
  const mutations = []
  await deliverInternalBuild(
    async (path, options = {}) => {
      if (options.method === "POST") {
        mutations.push(path)
        return
      }
      return { data: path === "builds" ? [validBuild] : [group] }
    },
    build,
    async () => assert.fail("A retry must not upload an existing build")
  )
  assert.deepEqual(mutations, ["betaGroups/group/relationships/builds"])
})

test("a matching external group is never used for internal delivery", async () => {
  await assert.rejects(
    internalGroup(
      async (path, options = {}) => {
        assert.equal(options.method, undefined)
        return { data: [{ ...group, attributes: { ...group.attributes, isInternalGroup: false } }] }
      },
      "app",
      "Alpha"
    ),
    /group Alpha is external/
  )
})
