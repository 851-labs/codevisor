import assert from "node:assert/strict"
import { test } from "node:test"
import { fileURLToPath } from "node:url"

import {
  fetchStatus,
  publishItem,
  uploadPackage,
  waitForUpload
} from "./publish-browser-extension.mjs"

const configuration = {
  accessToken: "test-token",
  publisherId: "test-publisher",
  extensionId: "test-extension"
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
  const upload = await uploadPackage(
    fileURLToPath(new URL("../../package.json", import.meta.url)),
    configuration,
    async (url, options) => {
      calls.push({ url, options })
      return jsonResponse({ crxVersion: "1.2.3", uploadState: "SUCCEEDED" })
    }
  )

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

test("API errors surface the Chrome Web Store message", async () => {
  await assert.rejects(
    fetchStatus(configuration, async () =>
      jsonResponse({ error: { message: "permission denied" } }, 403)
    ),
    /permission denied/
  )
})
