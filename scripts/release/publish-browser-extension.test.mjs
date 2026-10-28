import assert from "node:assert/strict"
import { test } from "node:test"
import { fileURLToPath } from "node:url"

import {
  fetchStatus,
  main,
  publishItem,
  uploadPackage,
  waitForUpload
} from "./publish-browser-extension.mjs"

const configuration = {
  accessToken: "test-token",
  publisherId: "test-publisher",
  extensionId: "test-extension"
}

const environment = {
  CHROME_WEBSTORE_ACCESS_TOKEN: "test-token",
  CHROME_WEBSTORE_PUBLISHER_ID: "test-publisher",
  CHROME_WEBSTORE_EXTENSION_ID: "test-extension"
}

const packagePath = fileURLToPath(new URL("../../package.json", import.meta.url))

const unexpectedFetch = () => {
  throw new Error("A dry run must not call the Chrome Web Store")
}

const jsonResponse = (body, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" }
  })

test("fetchStatus calls the Chrome Web Store v2 item endpoint", async () => {
  const calls = []
  const status = await fetchStatus(configuration, async (url, options) => {
    calls.push({ url, options })
    return jsonResponse({ lastAsyncUploadState: "SUCCEEDED" })
  })

  assert.equal(status.lastAsyncUploadState, "SUCCEEDED")
  assert.equal(
    calls[0].url,
    "https://chromewebstore.googleapis.com/v2/publishers/test-publisher/items/test-extension:fetchStatus"
  )
  assert.equal(calls[0].options.headers.Authorization, "Bearer test-token")
})

test("uploadPackage sends the ZIP as a media upload", async () => {
  const calls = []
  const upload = await uploadPackage(packagePath, configuration, async (url, options) => {
    calls.push({ url, options })
    return jsonResponse({ crxVersion: "1.2.3", uploadState: "SUCCEEDED" })
  })

  assert.equal(upload.uploadState, "SUCCEEDED")
  assert.equal(
    calls[0].url,
    "https://chromewebstore.googleapis.com/upload/v2/publishers/test-publisher/items/test-extension:upload"
  )
  assert.equal(calls[0].options.method, "POST")
  assert.equal(calls[0].options.headers["Content-Type"], "application/zip")
  assert.ok(calls[0].options.body instanceof Uint8Array)
})

test("waitForUpload polls until the asynchronous upload succeeds", async () => {
  const states = ["NOT_FOUND", "IN_PROGRESS", "SUCCEEDED"]
  let sleeps = 0
  const state = await waitForUpload(configuration, {
    initialState: "IN_PROGRESS",
    fetchImplementation: async () => jsonResponse({ lastAsyncUploadState: states.shift() }),
    intervalMilliseconds: 0,
    sleep: async () => {
      sleeps += 1
    }
  })

  assert.equal(state, "SUCCEEDED")
  assert.equal(sleeps, 3)
})

test("waitForUpload rejects failed uploads", async () => {
  await assert.rejects(
    waitForUpload(configuration, { initialState: "FAILED" }),
    /upload failed with state FAILED/
  )
})

test("publishItem requests immediate publishing and blocks on warnings", async () => {
  const calls = []
  const publication = await publishItem(configuration, async (url, options) => {
    calls.push({ url, options })
    return jsonResponse({ state: "PENDING_REVIEW" })
  })

  assert.equal(publication.state, "PENDING_REVIEW")
  assert.equal(
    calls[0].url,
    "https://chromewebstore.googleapis.com/v2/publishers/test-publisher/items/test-extension:publish"
  )
  assert.deepEqual(JSON.parse(calls[0].options.body), {
    publishType: "DEFAULT_PUBLISH",
    blockOnWarnings: true
  })
})

test("publishItem can stage an approved version instead of releasing it", async () => {
  const calls = []
  await publishItem(
    configuration,
    async (url, options) => {
      calls.push({ url, options })
      return jsonResponse({ state: "PENDING_REVIEW" })
    },
    "STAGED_PUBLISH"
  )

  assert.equal(JSON.parse(calls[0].options.body).publishType, "STAGED_PUBLISH")
})

test("API errors surface the Chrome Web Store message", async () => {
  await assert.rejects(
    fetchStatus(configuration, async () =>
      jsonResponse({ error: { message: "permission denied" } }, 403)
    ),
    /permission denied/
  )
})

test("a dry run checks the package without calling the Chrome Web Store", async (context) => {
  context.mock.method(globalThis, "fetch", unexpectedFetch)
  const logged = context.mock.method(console, "log", () => {})

  await main(["--staged", "--dry-run", packagePath], environment)

  assert.match(
    logged.mock.calls[0].arguments[0],
    /^Dry run: would upload package\.json \(\d+ bytes\) and submit it \(STAGED_PUBLISH\)\.$/
  )
})

test("a dry run of a publish-only submission calls nothing", async (context) => {
  context.mock.method(globalThis, "fetch", unexpectedFetch)
  const logged = context.mock.method(console, "log", () => {})

  await main(["--publish-only", "--dry-run"], environment)

  assert.equal(
    logged.mock.calls[0].arguments[0],
    "Dry run: would submit the uploaded package (DEFAULT_PUBLISH)."
  )
})

test("a dry run still requires the store configuration", async (context) => {
  context.mock.method(globalThis, "fetch", unexpectedFetch)

  await assert.rejects(
    main(["--dry-run", packagePath], {}),
    /CHROME_WEBSTORE_ACCESS_TOKEN is required/
  )
})
