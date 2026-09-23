import assert from "node:assert/strict"
import test from "node:test"

import {
  baselineName,
  buildLabel,
  parseBenchArguments,
  runDirectoryName
} from "./vnc-bench-lib.mjs"

test("each machine model has its own baseline file", () => {
  assert.equal(baselineName("Mac16,6"), "baseline-Mac16_6.json")
  assert.equal(baselineName(" MacBookPro18,2\n"), "baseline-MacBookPro18_2.json")
  assert.throws(() => baselineName("  "), /empty/)
})

test("wrapper flags are separated from the benchmark's own", () => {
  assert.deepEqual(parseBenchArguments(["--scenes", "typing", "--save-baseline"]), {
    saveBaseline: true,
    compare: true,
    againstMain: false,
    passThrough: ["--scenes", "typing"]
  })
  assert.equal(parseBenchArguments(["--against-main"]).againstMain, true)
  assert.equal(parseBenchArguments(["--no-compare"]).compare, false)
  assert.throws(() => parseBenchArguments(["--out", "x"]), /set by vnc:bench/)
})

test("build labels mark local changes", () => {
  assert.equal(buildLabel("0123456789abcdef\n", false), "0123456789ab")
  assert.equal(buildLabel("0123456789abcdef", true), "0123456789ab+dirty")
})

test("run directories sort by time and are path-safe", () => {
  assert.equal(runDirectoryName(new Date("2026-09-22T21:05:09.123Z")), "2026-09-22T210509Z")
})
