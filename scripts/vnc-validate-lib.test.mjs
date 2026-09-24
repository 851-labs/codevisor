import assert from "node:assert/strict"
import test from "node:test"

import {
  benchFailure,
  lastLine,
  parseValidateArguments,
  renderReport,
  reportDirectory,
  testCount
} from "./vnc-validate-lib.mjs"

test("an issue is required; layers can be skipped by name", () => {
  const options = parseValidateArguments([
    "--issue",
    "851-2311",
    "--skip",
    "tophat",
    "--bench",
    "--scenes typing"
  ])
  assert.equal(options.issue, "851-2311")
  assert.deepEqual([...options.skip], ["tophat"])
  assert.deepEqual(options.benchArgs, ["--scenes", "typing"])
  assert.throws(() => parseValidateArguments([]), /--issue is required/)
  assert.throws(() => parseValidateArguments(["--issue", "x"]), /--issue is required/)
  assert.throws(
    () => parseValidateArguments(["--issue", "851-1", "--skip", "lunch"]),
    /unknown layer/
  )
  assert.equal(parseValidateArguments(["--help"]).help, true)
})

test("reports live beside the other measurements, by date and issue", () => {
  assert.equal(
    reportDirectory(new Date("2026-09-23T06:00:00Z"), "851-2311"),
    "docs/measurements/vnc/2026-09-23-851-2311"
  )
})

test("the report passes only when every layer that ran passed", () => {
  const passing = renderReport({
    issue: "851-1",
    build: "abc",
    machine: "Mac16,6",
    results: [
      { layer: "tests", ok: true, seconds: 12, summary: "63 tests" },
      { layer: "tophat", skipped: true, summary: "--skip" }
    ]
  })
  assert.equal(passing.ok, true)
  assert.match(passing.text, /Verdict: \*\*PASS\*\*/)
  assert.match(passing.text, /\| tophat \| skipped \| – \|/)
  const failing = renderReport({
    issue: "851-1",
    build: "abc",
    machine: "m",
    results: [
      { layer: "tests", ok: true, seconds: 1, summary: "a|b" },
      { layer: "bench", ok: false, seconds: 90, summary: "1 regression", detail: "| table |" }
    ]
  })
  assert.equal(failing.ok, false)
  assert.match(failing.text, /a\\\|b/, "pipes in summaries are escaped")
  assert.match(failing.text, /## bench\n\n\| table \|/)
  assert.equal(
    renderReport({ issue: "i", build: "b", machine: "m", results: [] }).ok,
    false,
    "nothing ran"
  )
})

test("summaries come from the last matching output line", () => {
  assert.equal(lastLine("a\nvnc:interop: PASS — 3\nb\n", /^vnc:interop:/), "vnc:interop: PASS — 3")
  assert.equal(lastLine("nothing", /^x/), "")
})

test("test counts add up every binary a swift test run printed", () => {
  const output = [
    "Test run with 63 tests in 7 suites passed after 2.0 seconds.",
    "Test run with 16 tests in 5 suites passed after 0.02 seconds."
  ].join("\n")
  assert.deepEqual(testCount(output), { ran: 79, passed: true })
  assert.equal(
    testCount(`${output}\nTest run with 2 tests in 1 suite failed after 1 seconds.`).passed,
    false
  )
  assert.deepEqual(testCount("nothing"), { ran: 0, passed: false })
})

test("a failed bench's reasons appear in the report, fenced", () => {
  assert.equal(benchFailure("", ""), "")
  const text = benchFailure(
    "photo/lan run 1: took longer than 180 s\n\nvnc-server's last output:\n  boom",
    ""
  )
  assert.match(text, /\*\*vnc-bench failed \(this build\)\*\*/)
  assert.match(text, /```text\nphoto\/lan run 1: took longer than 180 s/)
  assert.match(text, /  boom\n```/)
  assert.doesNotMatch(text, /origin\/main/)
  assert.match(benchFailure("", "x"), /origin\/main/)
})
