import assert from "node:assert/strict"
import { createPublicKey, verify } from "node:crypto"
import test from "node:test"

import {
  AppStoreConnectError,
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
  attributes: { processingState: "VALID", buildAudienceType: "INTERNAL_ONLY", expired: false },
  relationships: { buildBetaDetail: { data: { type: "buildBetaDetails", id: "detail" } } }
}
const group = {
  id: "group",
  type: "betaGroups",
  attributes: { name: "Alpha", isInternalGroup: true }
}

function buildResponse(internalBuildState = "READY_FOR_BETA_TESTING") {
  return {
    data: [validBuild],
    included: [
      { type: "buildBetaDetails", id: "unrelated", attributes: { internalBuildState: "EXPIRED" } },
      { type: "buildBetaDetails", id: "detail", attributes: { internalBuildState } }
    ]
  }
}

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

function deliveryFixture({ post = () => {}, membership } = {}) {
  let assigned = false
  const counts = { posts: 0, reads: 0 }
  const client = async (path, options = {}) => {
    if (path === "builds" && options.query["filter[betaGroups]"]) {
      assert.equal(options.query["filter[id]"], "build")
      assert.equal(options.query["filter[betaGroups]"], "group")
      counts.reads += 1
      const present = membership ? await membership(counts.reads) : assigned
      return { data: present ? [validBuild] : [] }
    }
    if (path === "builds") return buildResponse()
    if (path === "betaGroups") return { data: [group] }
    assert.equal(path, "betaGroups/group/relationships/builds")
    assert.equal(options.method, "POST")
    assert.deepEqual(options.body, { data: [{ type: "builds", id: "build" }] })
    counts.posts += 1
    await post(counts.posts, options)
    assigned = true
  }
  const run = (options) =>
    deliverInternalBuild(
      client,
      build,
      async () => assert.fail("Existing builds must not upload"),
      options
    )
  return { counts, run }
}

function missingBuildError(id = "build", type = "builds", status = 404) {
  return new AppStoreConnectError(
    "POST",
    "betaGroups/group/relationships/builds",
    status,
    JSON.stringify({
      errors: [
        { code: "NOT_FOUND", detail: `There is no resource of type '${type}' with id '${id}'` }
      ]
    })
  )
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

test("readiness waits for the matching beta detail after processing becomes valid", async () => {
  const states = [
    { data: [] },
    { data: [{ attributes: { processingState: "PROCESSING" } }] },
    { data: [validBuild] },
    buildResponse("PROCESSING"),
    buildResponse("IN_EXPORT_COMPLIANCE_REVIEW"),
    buildResponse()
  ]
  const delays = []
  const result = await waitForBuild(
    async (path, { query }) => {
      assert.equal(path, "builds")
      assert.equal(query["filter[app]"], "app")
      assert.equal(query["filter[version]"], "42")
      assert.equal(query["filter[preReleaseVersion.version]"], "1.2.3")
      assert.equal(query["filter[preReleaseVersion.platform]"], "IOS")
      assert.equal(query.include, "buildBetaDetail")
      return states.shift()
    },
    build,
    {
      attempts: 6,
      interval: 100,
      sleep: async (milliseconds) => {
        delays.push(milliseconds)
      }
    }
  )
  assert.equal(result.id, "build")
  assert.equal(result.betaDetail.attributes.internalBuildState, "READY_FOR_BETA_TESTING")
  assert.deepEqual(delays, [100, 100, 100, 100, 100])
})

test("a build already in internal testing is ready without sleeping", async () => {
  const result = await waitForBuild(async () => buildResponse("IN_BETA_TESTING"), build, {
    sleep: async () => assert.fail("A ready build must not sleep")
  })
  assert.equal(result.id, "build")
})

test("unusable internal testing states fail with an actionable reason", async () => {
  for (const state of ["PROCESSING_EXCEPTION", "EXPIRED", "MISSING_EXPORT_COMPLIANCE"]) {
    await assert.rejects(
      waitForBuild(async () => buildResponse(state), build, {
        sleep: async () => assert.fail("Terminal states must not sleep")
      }),
      new RegExp(`cannot enter internal testing: ${state}`)
    )
  }
})

test("readiness timeout reports a valid build's missing beta detail", async () => {
  await assert.rejects(
    waitForBuild(async () => ({ data: [validBuild] }), build, { attempts: 1 }),
    /processing=VALID, internal=not available/
  )
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
  let assigned = false
  const client = async (path, options = {}) => {
    operations.push([path, options.method ?? "GET"])
    if (path === "builds" && options.query["filter[betaGroups]"])
      return { data: assigned ? [validBuild] : [] }
    if (path === "builds") return uploaded ? buildResponse() : { data: [] }
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
    assigned = true
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
    ["builds", "GET"],
    ["betaGroups/group/relationships/builds", "POST"],
    ["builds", "GET"]
  ])
})

test("a delivery retry reuses an uploaded build and its existing internal group", async () => {
  const fixture = deliveryFixture()
  await fixture.run(fakeClock())
  assert.deepEqual(fixture.counts, { posts: 1, reads: 2 })
})

test("rerunning an assigned build verifies membership without another write", async () => {
  const fixture = deliveryFixture({ membership: () => true })
  await fixture.run(fakeClock())
  assert.deepEqual(fixture.counts, { posts: 0, reads: 1 })
})

test("assignment retries the known build's 404 with capped backoff then verifies membership", async () => {
  const clock = fakeClock()
  const fixture = deliveryFixture({
    post: (attempt) => {
      if (attempt <= 4) throw missingBuildError()
    }
  })
  await fixture.run(clock)
  assert.deepEqual(clock.delays, [15_000, 30_000, 60_000, 60_000])
  assert.deepEqual(fixture.counts, { posts: 5, reads: 6 })
})

test("accepted assignment waits for visible membership without repeating the POST", async () => {
  const clock = fakeClock()
  const fixture = deliveryFixture({ membership: (read) => read >= 4 })
  await fixture.run(clock)
  assert.deepEqual(clock.delays, [15_000, 30_000])
  assert.deepEqual(fixture.counts, { posts: 1, reads: 4 })
})

test("a persistent build 404 stops at the deadline and preserves Apple's error", async () => {
  const clock = fakeClock()
  const error = missingBuildError()
  const fixture = deliveryFixture({
    post: () => {
      throw error
    }
  })
  await assert.rejects(fixture.run({ ...clock, assignmentTimeout: 40_000 }), (failure) => {
    assert.match(failure.message, /Timed out assigning TestFlight build build to Alpha/)
    assert.match(failure.message, /Last error: App Store Connect POST.*404/)
    assert.equal(failure.cause, error)
    return true
  })
  assert.equal(clock.now(), 40_000)
  assert.deepEqual(clock.delays, [15_000, 25_000])
  assert.equal(fixture.counts.posts, 2)
})

test("unconfirmed membership times out even when Apple accepted the assignment", async () => {
  const fixture = deliveryFixture({ membership: () => false })
  await assert.rejects(
    fixture.run({ ...fakeClock(), assignmentTimeout: 40_000 }),
    /assignment accepted, membership not visible/
  )
  assert.equal(fixture.counts.posts, 1)
})

test("assignment remains pending before the deadline and does not retry at the deadline", async () => {
  let elapsed = 0
  let settled = false
  const sleeping = Promise.withResolvers()
  const resume = Promise.withResolvers()
  const fixture = deliveryFixture({
    post: () => {
      throw missingBuildError()
    }
  })
  const delivery = fixture
    .run({
      assignmentTimeout: 15_000,
      now: () => elapsed,
      sleep: async (delay) => {
        assert.equal(delay, 15_000)
        sleeping.resolve()
        await resume.promise
      }
    })
    .finally(() => {
      settled = true
    })
  const rejected = assert.rejects(delivery, /Timed out assigning/)
  await sleeping.promise
  elapsed = 14_999
  assert.equal(settled, false)
  assert.equal(fixture.counts.posts, 1)
  elapsed = 15_000
  resume.resolve()
  await rejected
  assert.equal(fixture.counts.posts, 1)
})

test("assignment includes request time in the deadline and limits the request budget", async () => {
  let elapsed = 0
  const error = new Error("Request timed out")
  const fixture = deliveryFixture({
    post: (_attempt, options) => {
      assert.equal(options.timeout, 40_000)
      elapsed = 40_000
      throw error
    }
  })
  await assert.rejects(
    fixture.run({ assignmentTimeout: 40_000, now: () => elapsed }),
    (failure) => {
      assert.match(failure.message, /Timed out assigning.*Request timed out/)
      assert.equal(failure.cause, error)
      return true
    }
  )
  assert.deepEqual(fixture.counts, { posts: 1, reads: 1 })
})

test("assignment does not retry unrelated resources, authorization, validation, or malformed errors", async () => {
  for (const error of [
    missingBuildError("another-build"),
    missingBuildError("group", "betaGroups"),
    missingBuildError("build", "builds", 401),
    missingBuildError("build", "builds", 403),
    missingBuildError("build", "builds", 409),
    new AppStoreConnectError("POST", "betaGroups/group/relationships/builds", 404, "Not found"),
    new Error("Network connection lost")
  ]) {
    const fixture = deliveryFixture({
      post: () => {
        throw error
      }
    })
    await assert.rejects(
      fixture.run({
        sleep: async () => assert.fail("Permanent errors must not sleep")
      }),
      (failure) => failure === error
    )
    assert.equal(fixture.counts.posts, 1)
  }
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
