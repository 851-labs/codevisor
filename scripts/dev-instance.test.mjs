import assert from "node:assert/strict"
import test from "node:test"

import { sanitizeAmbientEnvironment } from "./dev-instance.mjs"
import { developmentLayout, localDevelopmentEnvironment } from "./dev-layout.mjs"

const profileKey = "CODEVISOR_SCREEN_SHARING_DIAGNOSTIC_PROFILE"

test("native diagnostic selection survives dev sanitization without inheriting app-hosted state", () => {
  // Preserve unknown spellings too: native validation must reject them visibly
  // instead of the runner silently turning the requested profile off.
  for (const selection of ["paced15-worker", "", "unknown-profile"]) {
    const supplied = {
      [profileKey]: selection,
      CODEVISOR_APP_HOSTED: "1",
      CODEVISOR_APP_BUNDLE_PATH: "/Applications/Other Codevisor.app",
      HERDMAN_APP_HOSTED: "1",
      CODEVISOR_DEV_PORT: "45123",
      PATH: "/usr/bin"
    }
    sanitizeAmbientEnvironment(supplied)
    const launch = localDevelopmentEnvironment(developmentLayout("/repo/worktree", {}), supplied)

    assert.equal(launch[profileKey], selection)
    assert.equal(launch.CODEVISOR_DEV_PORT, "45123")
    assert.equal(launch.PATH, "/usr/bin")
    assert.equal(Object.hasOwn(launch, "CODEVISOR_APP_HOSTED"), false)
    assert.equal(Object.hasOwn(launch, "CODEVISOR_APP_BUNDLE_PATH"), false)
    assert.equal(Object.hasOwn(launch, "HERDMAN_APP_HOSTED"), false)
  }
})

test("ordinary development does not acquire a screen-sharing diagnostic profile", () => {
  const supplied = { PATH: "/usr/bin", CODEVISOR_APP_HOSTED: "1" }
  sanitizeAmbientEnvironment(supplied)
  const launch = localDevelopmentEnvironment(developmentLayout("/repo/worktree", {}), supplied)

  assert.equal(Object.hasOwn(launch, profileKey), false)
  assert.equal(Object.hasOwn(supplied, profileKey), false)
})
