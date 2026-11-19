import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { mkdtempSync, readFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

const library = fileURLToPath(new URL("./tier2-lib.sh", import.meta.url))

function inLibrary(t, commands) {
  const dir = mkdtempSync(join(tmpdir(), "tier2-skip-"))
  t.after(() => rmSync(dir, { recursive: true, force: true }))
  const result = spawnSync("bash", ["-c", `source "$1"; ${commands}`, "bash", library, dir], {
    encoding: "utf8"
  })
  return { dir, ...result }
}

test("a skipped run leaves its reason in the run's directory for the report", (t) => {
  const { dir, status, stderr } = inLibrary(
    t,
    'tier2_skip viewer 16-window-drag-floor-1 "$2" "the host could not start"'
  )

  assert.equal(status, 0)
  assert.equal(readFileSync(join(dir, "viewer-skipped.txt"), "utf8"), "the host could not start\n")
  assert.match(stderr, /skipping 16-window-drag-floor-1: the host could not start/)
})

test("a barrier that fails names this Mac's own problem when it has one", (t) => {
  const own = inLibrary(t, 'tier2_unmet start "viewer preflight failed"')
  const other = inLibrary(t, "tier2_unmet start ok")

  assert.equal(own.stdout, "viewer preflight failed\n")
  assert.equal(other.stdout, "not ready at start\n")
})
