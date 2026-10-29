import { chmodSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it, onTestFinished } from "vitest"

import { makeFlagSupport, TRUSTED_LAUNCH, trustArgs } from "./trusted-launch.js"
import type { ProviderEnvironment } from "./types.js"

const cliDirectory = () => {
  const directory = mkdtempSync(join(tmpdir(), "codevisor-trust-flag-"))
  onTestFinished(() => rmSync(directory, { force: true, recursive: true }))
  return directory
}

const writeCli = (path: string, body: string) => {
  const staged = `${path}.next`
  writeFileSync(staged, `#!/bin/sh\necho "$@" >> "${path}.calls"\n${body}\n`)
  chmodSync(staged, 0o755)
  renameSync(staged, path)
  return path
}

const calls = (path: string) => readFileSync(`${path}.calls`, "utf8").trim().split("\n")

const environment = (supportsFlag?: ProviderEnvironment["supportsFlag"]): ProviderEnvironment => ({
  env: {},
  envFor: () => Promise.resolve({}),
  executableExists: () => true,
  locateExecutable: () => undefined,
  ...(supportsFlag === undefined ? {} : { supportsFlag })
})

describe("trusted launch flags", () => {
  it("passes Pi's --approve only when the installed Pi's help lists it", async () => {
    const directory = cliDirectory()
    const current = writeCli(
      join(directory, "pi"),
      'echo "  --approve, -a  Trust project-local files"'
    )
    const old = writeCli(join(directory, "old-pi"), 'echo "  --model <id>"')
    const supports = makeFlagSupport()

    expect(await trustArgs(environment(supports), current, TRUSTED_LAUNCH.pi, {})).toEqual([
      "--approve"
    ])
    expect(await trustArgs(environment(supports), old, TRUSTED_LAUNCH.pi, {})).toEqual([])
  })

  it("passes Grok's hidden --trust only when the installed Grok accepts it", async () => {
    const directory = cliDirectory()
    const current = writeCli(join(directory, "grok"), "exit 0")
    const old = writeCli(
      join(directory, "old-grok"),
      "echo \"error: unexpected argument '$1' found\" >&2\nexit 2"
    )
    const supports = makeFlagSupport()

    expect(await trustArgs(environment(supports), current, TRUSTED_LAUNCH.grok, {})).toEqual([
      "--trust"
    ])
    expect(await trustArgs(environment(supports), old, TRUSTED_LAUNCH.grok, {})).toEqual([])
    expect(
      await trustArgs(environment(supports), join(directory, "missing"), TRUSTED_LAUNCH.grok, {})
    ).toEqual([])
  })

  it("probes each binary once, and again after it's replaced by an update", async () => {
    const directory = cliDirectory()
    const path = writeCli(join(directory, "cursor-agent"), 'echo "  --model <id>"')
    const supports = makeFlagSupport()

    expect(await supports(path, TRUSTED_LAUNCH.cursor, {})).toBe(false)
    expect(await supports(path, TRUSTED_LAUNCH.cursor, {})).toBe(false)
    expect(calls(path)).toEqual(["--help"])

    writeCli(path, 'echo "  --trust  Trust the current workspace without prompting"')
    expect(await supports(path, TRUSTED_LAUNCH.cursor, {})).toBe(true)
    expect(calls(path)).toEqual(["--help", "--help"])
  })
})
