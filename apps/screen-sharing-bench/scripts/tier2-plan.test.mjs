import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import test from "node:test"
import { fileURLToPath } from "node:url"

const library = fileURLToPath(new URL("./tier2-lib.sh", import.meta.url))

function checkPlan(env) {
  return spawnSync("bash", ["-c", 'source "$1"; tier2_check_inputs', "bash", library], {
    encoding: "utf8",
    env: { PATH: process.env.PATH, TIER2_REPS: "4", TIER2_DURATION: "90", ...env }
  })
}

test("a plan that fits on a fast network is refused on the 1 Mbit/s one, whose runs take up to 90 s to be ready", () => {
  const fast = checkPlan({ TIER2_NETWORK: "N6" })
  const slow = checkPlan({ TIER2_NETWORK: "N7" })

  assert.equal(fast.status, 0, fast.stderr)
  assert.equal(slow.status, 1)
  assert.match(slow.stderr, /10 runs \(2040s with overhead\) don't fit the 1800s budget/)
})

test("only the runs on the 1 Mbit/s network get its longer allowance", () => {
  const result = checkPlan({
    TIER2_SCENES: "scroll,typing@N7",
    TIER2_REPS: "3",
    TIER2_DURATION: "60"
  })

  assert.equal(result.status, 1)
  assert.match(result.stderr, /15 runs \(1950s with overhead\)/)
})
