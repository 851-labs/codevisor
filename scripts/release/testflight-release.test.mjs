import assert from "node:assert/strict"
import test from "node:test"

import { AppStoreConnectError } from "./app-store-connect.mjs"
import { promoteTestFlightBuild, testFlightReleaseNotes } from "./testflight-release.mjs"

const configuration = { appId: "app", version: "1.2.3", buildNumber: "42" }
const notes = "Test the updated coding workflow."
const review = {
  contactFirstName: "Test",
  contactLastName: "Contact",
  contactEmail: "review@example.com",
  contactPhone: "+15555550100",
  demoAccountRequired: true,
  demoAccountName: "demo@example.com",
  demoAccountPassword: "fixture-password",
  notes: "Use the configured demo machine."
}

function fixture(overrides = {}) {
  const state = {
    buildExists: true,
    processingState: "VALID",
    audience: "APP_STORE_ELIGIBLE",
    expired: false,
    externalState: "READY_FOR_BETA_SUBMISSION",
    autoNotify: false,
    submission: undefined,
    group: undefined,
    assigned: false,
    localization: undefined,
    review,
    localizations: [
      {
        attributes: {
          locale: "en-US",
          description: "Codevisor beta",
          feedbackEmail: "feedback@example.com"
        }
      }
    ],
    ...overrides
  }
  const requests = []
  const resource = () => ({
    id: "build",
    type: "builds",
    attributes: {
      processingState: state.processingState,
      buildAudienceType: state.audience,
      expired: state.expired
    },
    relationships: { buildBetaDetail: { data: { type: "buildBetaDetails", id: "detail" } } }
  })
  const client = async (path, options = {}) => {
    const method = options.method ?? "GET"
    requests.push({ path, method, body: options.body, query: options.query })
    if (path === "builds") {
      if (options.query["filter[betaGroups]"]) {
        assert.equal(options.query["filter[id]"], "build")
        assert.equal(options.query["filter[betaGroups]"], "public")
        return { data: state.assigned ? [resource()] : [] }
      }
      assert.equal(options.query["filter[app]"], "app")
      assert.equal(options.query["filter[version]"], "42")
      assert.equal(options.query["filter[preReleaseVersion.version]"], "1.2.3")
      return {
        data: state.buildExists ? [resource()] : [],
        included: [
          {
            id: "detail",
            type: "buildBetaDetails",
            attributes: {
              externalBuildState: state.externalState,
              autoNotifyEnabled: state.autoNotify
            }
          }
        ]
      }
    }
    if (path === "apps/app/betaAppReviewDetail") return { data: { attributes: state.review } }
    if (path === "apps/app/betaAppLocalizations") return { data: state.localizations }
    if (path === "betaGroups" && method === "GET") {
      assert.equal(options.query["filter[app]"], "app")
      return {
        data: [state.group, state.legacyGroup].filter(
          (group) => group?.attributes.name === options.query["filter[name]"]
        )
      }
    }
    if (path === "betaGroups" && method === "POST") {
      assert.deepEqual(options.body.data.attributes, {
        name: "Beta",
        isInternalGroup: false,
        hasAccessToAllBuilds: false,
        publicLinkEnabled: false
      })
      assert.deepEqual(options.body.data.relationships.app.data, { type: "apps", id: "app" })
      state.group = { id: "public", type: "betaGroups", attributes: options.body.data.attributes }
      return { data: state.group }
    }
    if (path === "betaGroups/public" && method === "PATCH") {
      assert.deepEqual(options.body.data, {
        type: "betaGroups",
        id: "public",
        attributes: { name: "Beta" }
      })
      const existing = state.group ?? state.legacyGroup
      state.group = { ...existing, attributes: { ...existing.attributes, name: "Beta" } }
      state.legacyGroup = undefined
      return { data: state.group }
    }
    if (path === "betaGroups/public/relationships/builds") {
      assert.equal(method, "POST")
      assert.deepEqual(options.body, { data: [{ type: "builds", id: "build" }] })
      state.assigned = true
      return
    }
    if (path === "betaBuildLocalizations" && method === "GET") {
      assert.equal(options.query["filter[build]"], "build")
      assert.equal(options.query["filter[locale]"], "en-US")
      return { data: state.localization ? [state.localization] : [] }
    }
    if (path === "betaBuildLocalizations" || path === "betaBuildLocalizations/localization") {
      if (method === "POST") {
        assert.equal(options.body.data.attributes.locale, "en-US")
        assert.deepEqual(options.body.data.relationships.build.data, {
          type: "builds",
          id: "build"
        })
      } else assert.equal(method, "PATCH")
      state.localization = { id: "localization", attributes: options.body.data.attributes }
      return { data: state.localization }
    }
    if (path === "buildBetaDetails/detail") {
      assert.equal(method, "PATCH")
      assert.deepEqual(options.body, {
        data: { id: "detail", type: "buildBetaDetails", attributes: { autoNotifyEnabled: true } }
      })
      state.autoNotify = true
      return { data: {} }
    }
    if (path === "betaAppReviewSubmissions" && method === "GET") {
      assert.equal(options.query["filter[build]"], "build")
      return { data: state.submission ? [state.submission] : [] }
    }
    if (path === "betaAppReviewSubmissions" && method === "POST") {
      assert.deepEqual(options.body, {
        data: {
          type: "betaAppReviewSubmissions",
          relationships: { build: { data: { type: "builds", id: "build" } } }
        }
      })
      if (state.submit) return state.submit(state)
      state.submission = { id: "review", attributes: { betaReviewState: "WAITING_FOR_REVIEW" } }
      state.externalState = "WAITING_FOR_BETA_REVIEW"
      return { data: state.submission }
    }
    if (path === "buildBetaNotifications") {
      assert.equal(method, "POST")
      assert.deepEqual(options.body, {
        data: {
          type: "buildBetaNotifications",
          relationships: { build: { data: { type: "builds", id: "build" } } }
        }
      })
      state.externalState = "IN_BETA_TESTING"
      return { data: {} }
    }
    assert.fail(`Unexpected API call: ${method} ${path}`)
  }
  const run = (options = {}) =>
    promoteTestFlightBuild(client, configuration, {
      notes,
      sleep: async () => assert.fail("An immediately visible assignment must not sleep"),
      now: () => 0,
      ...options
    })
  const writes = () => requests.filter(({ method }) => method !== "GET")
  return { state, requests, run, writes }
}

test("release promotion configures only the exact build and submits without waiting for Apple", async () => {
  const f = fixture()
  const result = await f.run()
  assert.equal(result.status, "submitted")
  assert.equal(result.reviewState, "WAITING_FOR_REVIEW")
  assert.equal(f.state.autoNotify, true)
  assert.equal(f.state.assigned, true)
  assert.equal(f.state.localization.attributes.whatsNew, notes)
  assert.deepEqual(
    f.writes().map(({ path }) => path),
    [
      "betaBuildLocalizations",
      "buildBetaDetails/detail",
      "betaGroups",
      "betaGroups/public/relationships/builds",
      "betaAppReviewSubmissions"
    ]
  )
  f.requests.length = 0
  assert.equal((await f.run()).status, "submitted")
  assert.deepEqual(f.writes(), [])
})

test("preflight reads the live setup without writing metadata, assigning groups, or submitting", async () => {
  const f = fixture()
  assert.deepEqual(await f.run({ checkOnly: true }), {
    buildId: "build",
    groupName: "Beta",
    status: "checked",
    groupExists: false
  })
  assert.deepEqual(f.writes(), [])
})

test("existing public invitations and tester settings are preserved", async () => {
  const group = {
    id: "public",
    attributes: {
      name: "Beta",
      isInternalGroup: false,
      publicLinkEnabled: true,
      publicLink: "https://testflight.apple.com/join/example",
      publicLinkLimit: 100
    }
  }
  const f = fixture({ group })
  assert.equal((await f.run()).publicLink, group.attributes.publicLink)
  assert.equal(f.state.group, group)
  assert.equal(
    f.writes().some(({ path }) => path === "betaGroups" || path === "betaGroups/public"),
    false
  )
})

test("the former default group is renamed in place without republishing its active build", async () => {
  const legacyGroup = {
    id: "public",
    type: "betaGroups",
    attributes: {
      name: "Public Beta",
      isInternalGroup: false,
      publicLinkEnabled: true,
      publicLink: "https://testflight.apple.com/join/existing",
      publicLinkLimit: 100
    },
    relationships: { betaTesters: { data: [{ type: "betaTesters", id: "tester" }] } }
  }
  const f = fixture({
    legacyGroup,
    assigned: true,
    autoNotify: true,
    externalState: "IN_BETA_TESTING",
    localization: { id: "localization", attributes: { whatsNew: notes } }
  })
  assert.equal((await f.run({ checkOnly: true })).groupExists, true)
  assert.deepEqual(f.writes(), [])
  assert.equal(f.state.legacyGroup, legacyGroup)
  const result = await f.run()
  assert.equal(result.status, "testing")
  assert.equal(result.groupName, "Beta")
  assert.equal(result.renamedGroupFrom, "Public Beta")
  assert.equal(result.publicLink, legacyGroup.attributes.publicLink)
  assert.deepEqual(f.state.group, {
    ...legacyGroup,
    attributes: { ...legacyGroup.attributes, name: "Beta" }
  })
  assert.deepEqual(
    f.writes().map(({ method, path }) => [method, path]),
    [["PATCH", "betaGroups/public"]]
  )
  f.requests.length = 0
  assert.equal((await f.run()).renamedGroupFrom, undefined)
  assert.deepEqual(f.writes(), [])
})

test("an existing or custom external group takes precedence over the former default", async () => {
  for (const name of ["Beta", "Early Access"]) {
    const group = { id: "public", attributes: { name, isInternalGroup: false } }
    const legacyGroup = { id: "old", attributes: { name: "Public Beta", isInternalGroup: false } }
    const f = fixture({ group, legacyGroup })
    assert.equal((await f.run({ groupName: name })).groupName, name)
    assert.equal(f.state.group, group)
    assert.equal(f.state.legacyGroup, legacyGroup)
    assert.equal(
      f.requests.some(({ query }) => query?.["filter[name]"] === "Public Beta"),
      false
    )
    assert.equal(
      f.writes().some(({ path }) => path.startsWith("betaGroups/") && !path.endsWith("/builds")),
      false
    )
  }
})

test("already approved builds start testing and retries do not notify testers again", async () => {
  const f = fixture({
    externalState: "READY_FOR_BETA_TESTING",
    submission: { attributes: { betaReviewState: "APPROVED" } }
  })
  assert.equal((await f.run()).status, "notified")
  assert.equal(
    f.writes().some(({ path }) => path === "betaAppReviewSubmissions"),
    false
  )
  f.requests.length = 0
  assert.equal((await f.run()).status, "testing")
  assert.deepEqual(f.writes(), [])
})

test("a review already in progress is reused", async () => {
  const f = fixture({
    externalState: "IN_BETA_REVIEW",
    submission: { attributes: { betaReviewState: "IN_REVIEW" } }
  })
  assert.equal((await f.run()).reviewState, "IN_REVIEW")
  assert.equal(
    f.writes().some(({ path }) => path === "betaAppReviewSubmissions"),
    false
  )
})

test("a build eligible to start testing does not require another review submission", async () => {
  const f = fixture({ externalState: "READY_FOR_BETA_TESTING" })
  assert.equal((await f.run()).status, "notified")
  assert.equal(f.state.submission, undefined)
  assert.equal(f.state.externalState, "IN_BETA_TESTING")
})

test("immediate beta approval is reported separately from a pending review", async () => {
  const f = fixture({
    submit: () => ({ data: { attributes: { betaReviewState: "APPROVED" } } })
  })
  assert.equal((await f.run()).status, "approved")
  assert.equal(f.state.autoNotify, true)
  assert.equal(f.state.assigned, true)
})

test("invalid or incomplete release setup fails before any mutations", async () => {
  for (const [overrides, message] of [
    [{ buildExists: false }, /has not been uploaded/],
    [{ audience: "INTERNAL_ONLY" }, /Internal Only/],
    [{ expired: true }, /expired/],
    [{ processingState: "PROCESSING" }, /still processing/],
    [{ processingState: "INVALID" }, /could not process.*INVALID/],
    [{ processingState: "FAILED" }, /could not process.*FAILED/],
    [{ externalState: "MISSING_EXPORT_COMPLIANCE" }, /MISSING_EXPORT_COMPLIANCE/],
    [{ externalState: "IN_EXPORT_COMPLIANCE_REVIEW" }, /IN_EXPORT_COMPLIANCE_REVIEW/],
    [{ externalState: "BETA_REJECTED" }, /rejected/],
    [{ externalState: "unknown" }, /unknown/],
    [{ submission: { attributes: { betaReviewState: "REJECTED" } } }, /rejected/],
    [{ review: { ...review, demoAccountPassword: "" } }, /demoAccountPassword/],
    [{ review: { ...review, demoAccountRequired: false } }, /sign-in required/],
    [{ review: { ...review, contactPhone: "" } }, /contactPhone/],
    [{ localizations: [] }, /beta app description/],
    [
      {
        localizations: [{ attributes: { locale: "en-US", feedbackEmail: "feedback@example.com" } }]
      },
      /description \(en-US\)/
    ],
    [
      { localizations: [{ attributes: { locale: "en-US", description: "Beta" } }] },
      /feedback email/
    ],
    [{ group: { attributes: { name: "Beta", isInternalGroup: true } } }, /must be external/],
    [
      { legacyGroup: { attributes: { name: "Public Beta", isInternalGroup: true } } },
      /must be external/
    ],
    [
      {
        group: { attributes: { name: "Public Beta", isInternalGroup: false } },
        legacyGroup: { attributes: { name: "Public Beta", isInternalGroup: false } }
      },
      /Multiple TestFlight groups/
    ]
  ]) {
    const f = fixture(overrides)
    await assert.rejects(f.run(), message)
    assert.deepEqual(f.writes(), [])
  }
})

test("invalid release notes and empty group names fail without contacting Apple", async () => {
  const f = fixture()
  for (const options of [{ notes: "" }, { notes: "x".repeat(4001) }, { groupName: " " }])
    await assert.rejects(f.run(options), /notes|group name/)
  assert.deepEqual(f.requests, [])
})

test("an existing What to Test localization is updated in place", async () => {
  const f = fixture({ localization: { id: "localization", attributes: { whatsNew: "Old notes" } } })
  await f.run()
  const mutations = f.writes().filter(({ path }) => path.startsWith("betaBuildLocalizations"))
  assert.equal(mutations.length, 1)
  assert.equal(mutations[0].method, "PATCH")
  assert.equal(mutations[0].path, "betaBuildLocalizations/localization")
})

test("a submission conflict resumes only when that exact build has an accepted submission", async () => {
  const conflict = new AppStoreConnectError("POST", "betaAppReviewSubmissions", 409, "Conflict")
  const f = fixture({
    submit: (state) => {
      state.submission = { id: "review", attributes: { betaReviewState: "WAITING_FOR_REVIEW" } }
      throw conflict
    }
  })
  assert.equal((await f.run()).reviewState, "WAITING_FOR_REVIEW")
  const limited = fixture({
    submit: () => {
      throw conflict
    }
  })
  await assert.rejects(limited.run(), (error) => error === conflict)
  assert.equal(limited.writes().filter(({ path }) => path === "betaAppReviewSubmissions").length, 1)
})

test("release notes fit Apple's limit and retain a link to the complete release", () => {
  const url = "https://github.com/851-labs/codevisor/releases/tag/v1.2.3"
  const markdown =
    "# Codevisor 1.2.3\n\n## Changed\n\n- Improve sign-in ([abcdef0](https://github.com/851-labs/codevisor/commit/abcdef0))\n"
  const result = testFlightReleaseNotes("1.2.3", markdown, url)
  assert.match(result, /Changed\n\n- Improve sign-in/)
  assert.equal(result.includes("abcdef0"), false)
  assert.ok(result.endsWith(url))
  const long = testFlightReleaseNotes("1.2.3", "- An update\n".repeat(1000), url)
  assert.ok(long.length <= 4000)
  assert.ok(long.includes("…"))
  assert.ok(long.endsWith(url))
  assert.throws(() => testFlightReleaseNotes("1.2.3", " ", url), /must not be empty/)
})
