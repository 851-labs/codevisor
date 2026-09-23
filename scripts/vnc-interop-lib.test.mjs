import assert from "node:assert/strict"
import test from "node:test"

import {
  checkTestRun,
  defaults,
  imageTag,
  interopEnvironment,
  parseDockerPort,
  parseInteropArguments
} from "./vnc-interop-lib.mjs"

test("arguments default to the interop suites and a 1024x768 desktop", () => {
  assert.deepEqual(parseInteropArguments([]), {
    keep: false,
    filter: "InteropTests",
    geometry: "1024x768"
  })
  assert.deepEqual(
    parseInteropArguments(["--keep", "--filter", "RFBInteropTests", "--geometry", "1280x800"]),
    {
      keep: true,
      filter: "RFBInteropTests",
      geometry: "1280x800"
    }
  )
  assert.throws(() => parseInteropArguments(["--geometry", "big"]), /WxH/)
  assert.throws(() => parseInteropArguments(["--filter"]), /needs a value/)
  assert.throws(() => parseInteropArguments(["--nope"]), /Unknown argument/)
})

test("the image tag changes with the build context and nothing else", () => {
  const a = imageTag({ Dockerfile: "FROM x", "entrypoint.sh": "run" })
  assert.match(a, /^codevisor-vnc-interop:[0-9a-f]{12}$/)
  assert.equal(
    imageTag({ "entrypoint.sh": "run", Dockerfile: "FROM x" }),
    a,
    "order doesn't matter"
  )
  assert.notEqual(imageTag({ Dockerfile: "FROM y", "entrypoint.sh": "run" }), a)
})

test("the loopback host port is read from docker port", () => {
  assert.equal(parseDockerPort("127.0.0.1:55012\n"), 55012)
  assert.equal(parseDockerPort("[::1]:55013\n127.0.0.1:55012\n"), 55012)
  assert.throws(() => parseDockerPort("0.0.0.0:5901\n"), /No 127.0.0.1 binding/)
})

test("the tests are pointed at the container with its known desktop", () => {
  assert.deepEqual(
    interopEnvironment({
      port: 55012,
      password: defaults.password,
      geometry: "1024x768",
      rootColor: "336699"
    }),
    {
      VNC_TEST_HOST: "127.0.0.1",
      VNC_TEST_PORT: "55012",
      VNC_TEST_PASSWORD: "codevisor",
      VNC_TEST_GEOMETRY: "1024x768",
      VNC_TEST_ROOT_COLOR: "336699"
    }
  )
})

test("the gate needs tests that ran, weren't skipped and passed", () => {
  const passed = "✔ Test run with 2 tests in 2 suites passed after 1.2 seconds."
  assert.deepEqual(checkTestRun(passed), {
    ran: 2,
    skipped: 0,
    failed: false,
    ok: true,
    problems: []
  })
  assert.equal(
    checkTestRun("Test run with 0 tests in 0 suites passed after 0.001 seconds.").ok,
    false
  )
  const skipped =
    "Test connectsAndReceivesTheFirstUpdate() skipped.\nTest run with 2 tests in 2 suites passed after 0.1 seconds."
  assert.deepEqual(checkTestRun(skipped).problems, ["1 interop test(s) skipped"])
  const failed = "Test run with 2 tests in 2 suites failed after 3.0 seconds with 1 issue."
  assert.deepEqual(checkTestRun(failed).problems, ["interop tests failed"])
})
