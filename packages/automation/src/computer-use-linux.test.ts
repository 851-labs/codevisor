import { spawnSync } from "node:child_process"
import { fileURLToPath } from "node:url"
import { expect, it } from "vitest"

it("validates the Linux helper's observations, targets and input lifecycle", () => {
  const result = spawnSync(
    "python3",
    [fileURLToPath(new URL("../tests/computer-use-linux.test.py", import.meta.url))],
    { encoding: "utf8" }
  )
  expect(result.error).toBeUndefined()
  expect(result.status, result.stdout + result.stderr).toBe(0)
})
