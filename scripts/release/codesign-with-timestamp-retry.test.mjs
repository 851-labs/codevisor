import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

const wrapper = fileURLToPath(new URL("./codesign-with-timestamp-retry.sh", import.meta.url))
const unavailable = "The timestamp service is not available."

async function fakeTools(t, failures) {
  const bin = await mkdtemp(join(tmpdir(), "codevisor-codesign-retry-"))
  t.after(() => rm(bin, { recursive: true, force: true }))
  const log = join(bin, "log")
  await writeFile(log, "")
  const failuresFile = join(bin, "failures")
  await writeFile(failuresFile, failures.join("\n"))
  await writeExecutable(
    join(bin, "codesign"),
    `echo "codesign $*" >> "${log}"
attempt=$(grep -c '^codesign' "${log}")
failure=$(sed -n "\${attempt}p" "${failuresFile}")
[[ -n "$failure" ]] || { echo "$1: replacing existing signature" >&2; exit 0; }
echo "$failure" >&2
exit 1`
  )
  await writeExecutable(join(bin, "sleep"), `echo "sleep $*" >> "${log}"`)
  return { bin, log }
}

async function writeExecutable(path, body) {
  await writeFile(path, `#!/usr/bin/env bash\n${body}\n`)
  await chmod(path, 0o755)
}

async function sign(t, failures) {
  const tools = await fakeTools(t, failures)
  const result = spawnSync(wrapper, ["--force", "--timestamp", "Fixture.framework"], {
    encoding: "utf8",
    env: { ...process.env, PATH: `${tools.bin}:${process.env.PATH}` }
  })
  const log = (await readFile(tools.log, "utf8")).trim().split("\n")
  return { status: result.status, stderr: result.stderr, log }
}

test("an unavailable timestamp service is retried with backoff until codesign succeeds", async (t) => {
  const { status, stderr, log } = await sign(t, [
    `Fixture.framework: ${unavailable}`,
    `Fixture.framework: ${unavailable}`
  ])
  assert.equal(status, 0)
  assert.deepEqual(log, [
    "codesign --force --timestamp Fixture.framework",
    "sleep 15",
    "codesign --force --timestamp Fixture.framework",
    "sleep 30",
    "codesign --force --timestamp Fixture.framework"
  ])
  assert.match(stderr, /replacing existing signature/)
})

test("a timestamp outage that outlasts every attempt fails with codesign's error", async (t) => {
  const { status, stderr, log } = await sign(t, Array(4).fill(`Fixture.framework: ${unavailable}`))
  assert.equal(status, 1)
  assert.equal(log.filter((line) => line.startsWith("codesign")).length, 4)
  assert.deepEqual(
    log.filter((line) => line.startsWith("sleep")),
    ["sleep 15", "sleep 30", "sleep 60"]
  )
  assert.match(stderr, /timestamp service is not available/)
})

test("other signing failures fail immediately", async (t) => {
  const { status, stderr, log } = await sign(t, ["Fixture.framework: no identity found"])
  assert.equal(status, 1)
  assert.deepEqual(log, ["codesign --force --timestamp Fixture.framework"])
  assert.match(stderr, /no identity found/)
})
