import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { test } from "node:test"
import { fileURLToPath } from "node:url"

test("runner cleanup respects active jobs, open files, and deletion boundaries", () => {
  const result = spawnSync(
    "python3",
    [fileURLToPath(new URL("./ci-runner-maintenance/test_cleanup.py", import.meta.url))],
    { encoding: "utf8", timeout: 30_000 }
  )
  assert.equal(result.status, 0, result.stderr || result.error?.message)
})
