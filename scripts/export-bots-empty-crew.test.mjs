import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { dirname, resolve } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..")

test("the bundled Bots empty-state mascots match what the server draws", () => {
  const check = spawnSync("bun", ["run", "mascots:export-crew", "--check"], {
    cwd: root,
    encoding: "utf8"
  })

  assert.equal(check.status, 0, check.stderr)
})
