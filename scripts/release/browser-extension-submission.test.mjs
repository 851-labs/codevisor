import assert from "node:assert/strict"
import { test } from "node:test"

import {
  decideSubmission,
  extensionSource,
  latestSubmissionBefore
} from "./browser-extension-submission.mjs"

const unreachable = () => {
  throw new Error("The source should not be compared")
}

test("submits the first version when nothing was submitted before", () => {
  assert.deepEqual(decideSubmission({ version: "0.1.109", tags: [], changedSince: unreachable }), {
    submit: true,
    reason: "No earlier submission is recorded."
  })
})

test("skips a version that was already submitted", () => {
  const decision = decideSubmission({
    version: "0.1.109",
    tags: ["browser-extension-v0.1.109"],
    changedSince: unreachable
  })

  assert.deepEqual(decision, { submit: false, reason: "0.1.109 was already submitted." })
})

test("submits when the extension source changed since the last submission", () => {
  const compared = []
  const decision = decideSubmission({
    version: "0.1.109",
    tags: ["browser-extension-v0.1.100"],
    changedSince: (tag) => {
      compared.push(tag)
      return true
    }
  })

  assert.deepEqual(compared, ["browser-extension-v0.1.100"])
  assert.deepEqual(decision, {
    submit: true,
    reason: `${extensionSource} changed since 0.1.100 was submitted.`
  })
})

test("skips when the extension source is unchanged since the last submission", () => {
  const decision = decideSubmission({
    version: "0.1.109",
    tags: ["browser-extension-v0.1.100"],
    changedSince: () => false
  })

  assert.deepEqual(decision, {
    submit: false,
    reason: `${extensionSource} is unchanged since 0.1.100 was submitted.`
  })
})

test("compares against the newest earlier submission by numeric version", () => {
  const tags = [
    "browser-extension-v0.1.9",
    "browser-extension-v0.1.100",
    "browser-extension-v0.1.12",
    "browser-extension-v0.2.0",
    "browser-extension-v0.1.101-alpha.2",
    "v0.1.105"
  ]

  assert.equal(latestSubmissionBefore("0.1.109", tags), "0.1.100")
})
