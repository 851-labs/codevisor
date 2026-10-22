import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { onTestFinished } from "vitest"

export const testTempDir = (prefix: string): string => {
  const root = mkdtempSync(join(tmpdir(), prefix))
  onTestFinished(() => rmSync(root, { recursive: true, force: true }))
  return root
}

export const isolatedEnv = (bin: string): NodeJS.ProcessEnv => {
  const home = testTempDir("codevisor-git-host-home-")
  return {
    PATH: `${bin}:/usr/bin:/bin`,
    HOME: home,
    GH_CONFIG_DIR: join(home, "gh"),
    GLAB_CONFIG_DIR: join(home, "glab"),
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_CONFIG_NOSYSTEM: "1"
  }
}

export const writeScript = (path: string, script: string): string => {
  writeFileSync(path, `#!/bin/sh\n${script}\n`)
  chmodSync(path, 0o755)
  return path
}

export interface FakeCli {
  readonly env: NodeJS.ProcessEnv
  readonly bin: string
  readonly path: string
}

export const fakeCli = (name: string, script: string): FakeCli => {
  const bin = join(testTempDir(`codevisor-fake-${name}-`), "bin")
  mkdirSync(bin)
  const path = writeScript(join(bin, name), script)
  return { env: isolatedEnv(bin), bin, path }
}

export const emptyEnv = (): NodeJS.ProcessEnv => isolatedEnv(testTempDir("codevisor-empty-bin-"))
