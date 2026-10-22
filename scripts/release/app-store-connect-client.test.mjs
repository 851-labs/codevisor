import assert from "node:assert/strict"
import { createPublicKey, verify } from "node:crypto"
import test from "node:test"

import {
  AppStoreConnectError,
  appStoreClient,
  appStoreToken,
  findApp
} from "./app-store-connect.mjs"

const privateKey = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgzCncWVIrLZn98Skm
aMBqCDEJbkF+dDR7f8xgXFr4k6uhRANCAARsJMG/JX/pUF7QgVsxX30DiMyEtw3r
HFugpyUpdCsX+Z3SrfPyq7+v21XbnOeDnUjdMNXtTJ4cd++x1lbBQLKn
-----END PRIVATE KEY-----`
const credentials = { privateKey, keyId: "EXAMPLEKEY", issuerId: "example-issuer" }
function fakeClock() {
  let elapsed = 0
  const delays = []
  return {
    delays,
    now: () => elapsed,
    sleep: async (milliseconds) => {
      delays.push(milliseconds)
      elapsed += milliseconds
    }
  }
}

const decode = (value) => JSON.parse(Buffer.from(value, "base64url"))

test("API authentication creates an ES256 token with Apple's audience and a bounded lifetime", () => {
  const token = appStoreToken(credentials, 1_700_000_000_000)
  const [header, payload, signature] = token.split(".")
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

function scriptedClient(responses, clock) {
  const requests = []
  const client = appStoreClient(credentials, {
    now: clock.now,
    sleep: clock.sleep,
    fetchImplementation: async (url, options) => {
      requests.push({ path: url.pathname, method: options.method })
      const next = responses[Math.min(requests.length, responses.length) - 1]
      if (next instanceof Error) throw next
      return next()
    }
  })
  return { client, requests }
}

const appleOutage = () =>
  Response.json({ errors: [{ status: "500", code: "UNEXPECTED_ERROR" }] }, { status: 500 })

test("reads ride out Apple's transient server and network failures with backoff", async () => {
  const clock = fakeClock()
  const { client, requests } = scriptedClient(
    [
      appleOutage,
      new TypeError("fetch failed"),
      () => new Response("Too many requests", { status: 429 }),
      () => Response.json({ data: [{ id: "app" }] })
    ],
    clock
  )
  assert.deepEqual(await findApp(client, "com.example.app"), { id: "app" })
  assert.equal(requests.length, 4)
  assert.deepEqual(clock.delays, [5_000, 15_000, 30_000])
})

test("a persistent read outage stops within the request budget and keeps Apple's error", async () => {
  const clock = fakeClock()
  const { client, requests } = scriptedClient([appleOutage], clock)
  await assert.rejects(client("apps", { timeout: 30_000 }), (error) => {
    assert.ok(error instanceof AppStoreConnectError)
    assert.equal(error.status, 500)
    assert.equal(error.errors[0].code, "UNEXPECTED_ERROR")
    return true
  })
  assert.equal(requests.length, 3)
  assert.deepEqual(clock.delays, [5_000, 15_000])
})

test("writes and client errors are never retried", async () => {
  const clock = fakeClock()
  const writes = scriptedClient([appleOutage], clock)
  await assert.rejects(
    writes.client("betaGroups", { method: "POST", body: {} }),
    /POST betaGroups failed \(500\)/
  )
  assert.equal(writes.requests.length, 1)

  const reads = scriptedClient([() => new Response("Not found", { status: 404 })], clock)
  await assert.rejects(reads.client("apps"), /GET apps failed \(404\)/)
  assert.equal(reads.requests.length, 1)
  assert.deepEqual(clock.delays, [])
})

test("API errors expose HTTP status and Apple error details for retry classification", async () => {
  const body = { errors: [{ code: "NOT_FOUND", detail: "A resource is missing" }] }
  const client = appStoreClient(credentials, {
    now: () => 1_700_000_000_000,
    fetchImplementation: async () => Response.json(body, { status: 404 })
  })
  await assert.rejects(
    client("betaGroups/group/relationships/builds", { method: "POST" }),
    (error) => {
      assert.ok(error instanceof AppStoreConnectError)
      assert.equal(error.status, 404)
      assert.equal(error.method, "POST")
      assert.equal(error.path, "betaGroups/group/relationships/builds")
      assert.deepEqual(error.errors, body.errors)
      return true
    }
  )
})
