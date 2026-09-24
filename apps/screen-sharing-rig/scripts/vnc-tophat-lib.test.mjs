import assert from "node:assert/strict"
import test from "node:test"

import { clipboardToken, parseTophatArguments, parseWindow, summarize } from "./vnc-tophat-lib.mjs"

test("the loopback flow runs by default; Contabo is opt-in", () => {
  assert.deepEqual(parseTophatArguments([]), { machines: ["loopback"], build: true })
  assert.deepEqual(parseTophatArguments(["--machines", "loopback,contabo", "--no-build"]), {
    machines: ["loopback", "contabo"],
    build: false
  })
  assert.throws(() => parseTophatArguments(["--machines", "mars"]), /unknown machine/)
  assert.throws(() => parseTophatArguments(["--machines"]), /needs a value/)
})

test("a run passes only when every step passed", () => {
  assert.deepEqual(summarize([{ name: "a", ok: true }]), { ok: true, passed: 1, failed: [] })
  const failed = summarize([
    { name: "a", ok: true },
    { name: "b", ok: false, detail: "x" }
  ])
  assert.equal(failed.ok, false)
  assert.deepEqual(failed.failed, [{ name: "b", ok: false, detail: "x" }])
  assert.equal(summarize([]).ok, false, "no steps is not a pass")
})

test("the window line names the CGWindow for screenshots", () => {
  assert.deepEqual(parseWindow("Loopback server – x\t8456\t1180\t760\n"), {
    title: "Loopback server – x",
    number: 8456,
    width: 1180,
    height: 760
  })
  assert.throws(() => parseWindow("\t0\t0\t0"), /No window/)
})

test("clipboard tokens are distinct per run", () => {
  assert.equal(clipboardToken(35), "codevisor-tophat-z 日本語 😀")
  assert.notEqual(clipboardToken(1), clipboardToken(2))
})
