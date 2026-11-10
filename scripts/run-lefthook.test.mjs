import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

const runner = fileURLToPath(new URL("./git-hooks/run-lefthook.sh", import.meta.url))
const pathWithoutBun = "/usr/bin:/bin"

const withHome = (body) => {
  const home = mkdtempSync(join(tmpdir(), "run-lefthook-"))
  try {
    body(home)
  } finally {
    rmSync(home, { recursive: true, force: true })
  }
}

const installFakeBun = (dir) => {
  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, "bun"), '#!/bin/sh\nprintf "%s\\n" "$*" "$PATH"\n')
  chmodSync(join(dir, "bun"), 0o755)
}

const runHook = (home, ...args) =>
  spawnSync(runner, args, {
    encoding: "utf8",
    env: { HOME: home, HOMEBREW_PREFIX: join(home, "homebrew"), PATH: pathWithoutBun }
  })

test("a bun installed outside PATH runs lefthook and stays reachable for hook commands", () => {
  withHome((home) => {
    const bunDir = join(home, ".local/share/vite-plus/bin")
    installFakeBun(bunDir)

    const result = runHook(home, "run", "pre-commit")

    assert.equal(result.status, 0, result.stderr)
    assert.deepEqual(result.stdout.trim().split("\n"), [
      "x lefthook run pre-commit",
      `${pathWithoutBun}:${bunDir}`
    ])
  })
})

test("a post-checkout hook without bun lets the checkout finish quietly", () => {
  withHome((home) => {
    const result = runHook(home, "run", "post-checkout", "0", "1", "1")

    assert.equal(result.status, 0)
    assert.equal(result.stderr, "")
  })
})

test("pre-commit and pre-push without bun stop git and say why", () => {
  withHome((home) => {
    for (const hook of ["pre-commit", "pre-push"]) {
      const result = runHook(home, "run", hook)

      assert.equal(result.status, 1, hook)
      assert.match(
        result.stderr,
        new RegExp(`lefthook run ${hook}: bun isn't installed or on PATH`)
      )
    }
  })
})
