import assert from "node:assert/strict"
import test from "node:test"

import { wantsContainerDesktop } from "./dev-containers.mjs"
import { sanitizeAmbientEnvironment } from "./dev-instance.mjs"
import { developmentLayout, localDevelopmentEnvironment } from "./dev-layout.mjs"

test("dev sanitization keeps dev settings without inheriting app-hosted state", () => {
  const supplied = {
    CODEVISOR_APP_HOSTED: "1",
    CODEVISOR_APP_BUNDLE_PATH: "/Applications/Other Codevisor.app",
    HERDMAN_APP_HOSTED: "1",
    CODEVISOR_DEV_PORT: "45123",
    PATH: "/usr/bin"
  }
  sanitizeAmbientEnvironment(supplied)
  const launch = localDevelopmentEnvironment(developmentLayout("/repo/worktree", {}), supplied)

  assert.equal(launch.CODEVISOR_DEV_PORT, "45123")
  assert.equal(launch.PATH, "/usr/bin")
  assert.equal(Object.hasOwn(launch, "CODEVISOR_APP_HOSTED"), false)
  assert.equal(Object.hasOwn(launch, "CODEVISOR_APP_BUNDLE_PATH"), false)
  assert.equal(Object.hasOwn(launch, "HERDMAN_APP_HOSTED"), false)
})

test("the dev container desktop opt-in survives dev sanitization", () => {
  const supplied = { CODEVISOR_DEV_CONTAINER_DESKTOP: "1", PATH: "/usr/bin" }
  sanitizeAmbientEnvironment(supplied)
  assert.equal(wantsContainerDesktop(supplied), true)
  assert.equal(wantsContainerDesktop({ PATH: "/usr/bin" }), false)
})
