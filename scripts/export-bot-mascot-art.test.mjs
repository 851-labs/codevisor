import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { dirname, resolve } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..")

test("the apps bundle the mascot art the server package builds", () => {
  const check = spawnSync("bun", ["run", "mascots:export-art", "--check"], {
    cwd: root,
    encoding: "utf8"
  })

  assert.equal(check.status, 0, check.stderr)
})
