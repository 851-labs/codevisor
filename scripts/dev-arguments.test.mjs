import assert from "node:assert/strict"
import test from "node:test"

import { parseDevelopmentRunnerArguments } from "./dev-arguments.mjs"

test("native development runners use containers by default", () => {
  assert.deepEqual(parseDevelopmentRunnerArguments([]), {
    containerEnginePreference: undefined,
    wantsContainers: true
  })
  assert.equal(parseDevelopmentRunnerArguments(["--containers"]).wantsContainers, true)
})

test("native development runners share container opt-out and engine flags", () => {
  assert.equal(parseDevelopmentRunnerArguments(["--no-containers"]).wantsContainers, false)
  assert.deepEqual(parseDevelopmentRunnerArguments(["--container-engine=docker"]), {
    containerEnginePreference: "docker",
    wantsContainers: true
  })
  assert.deepEqual(parseDevelopmentRunnerArguments(["--container-engine=none"]), {
    containerEnginePreference: "none",
    wantsContainers: false
  })
  assert.throws(
    () => parseDevelopmentRunnerArguments(["--container-engine=bogus"]),
    /Unknown container engine: bogus/
  )
})

test("a runner can add private plumbing flags without widening the public surface", () => {
  assert.equal(
    parseDevelopmentRunnerArguments(["--no-ios"], { allowedArguments: ["--no-ios"] })
      .wantsContainers,
    true
  )
  assert.throws(
    () => parseDevelopmentRunnerArguments(["--no-ios"]),
    /Unknown development runner argument: --no-ios/
  )
  assert.throws(
    () => parseDevelopmentRunnerArguments(["--surprise"]),
    /Unknown development runner argument: --surprise/
  )
})
