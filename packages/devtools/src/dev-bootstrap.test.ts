import { chmod, mkdir, mkdtemp, readFile, readlink, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, expect, it, vi } from "vitest"

import { bootstrapDevelopment } from "./dev-bootstrap.ts"
import { GHOSTTY_SLICES } from "./ghostty-artifact.ts"

const cleanups: Array<() => Promise<unknown>> = []
afterEach(async () => {
  await Promise.all(cleanups.splice(0).map((cleanup) => cleanup()))
})

const executable = async (path: string, body: string) => {
  await writeFile(path, body)
  await chmod(path, 0o755)
}

async function fixture() {
  vi.spyOn(console, "log").mockImplementation(() => {})
  const root = await mkdtemp(join(tmpdir(), "codevisor-bootstrap-"))
  cleanups.push(() => rm(root, { recursive: true, force: true }))
  const repoRoot = join(root, "repo")
  const bin = join(root, "bin")
  const log = join(root, "calls.txt")
  const native = join(repoRoot, "packages/net/native/apple")
  const ghostty = join(repoRoot, "apps/macos/Frameworks/GhosttyKit.xcframework")
  for (const directory of [
    bin,
    join(repoRoot, "node_modules/.bin"),
    join(repoRoot, "apps/macos/scripts")
  ]) {
    await mkdir(directory, { recursive: true })
  }
  await executable(join(bin, "bun"), `#!/bin/sh\necho "bun $*" >> "${log}"\n`)
  await executable(
    join(repoRoot, "node_modules/.bin/turbo"),
    `#!/bin/sh\necho "turbo $2" >> "${log}"\nmkdir -p "${native}/CodevisorNetFFI.xcframework" && echo "// ffi" > "${native}/codevisor_net_ffi.swift"\n`
  )
  await executable(
    join(repoRoot, "apps/macos/scripts/build-ghostty.sh"),
    "#!/bin/sh\necho stamp-1\n"
  )
  for (const slice of GHOSTTY_SLICES) {
    await mkdir(join(ghostty, slice, "Headers/GhosttyKit"), { recursive: true })
    for (const file of [
      "Headers/GhosttyKit/ghostty.h",
      "Headers/GhosttyKit/module.modulemap",
      "ghostty-internal.a"
    ]) {
      await writeFile(join(ghostty, slice, file), "")
    }
  }
  await writeFile(join(ghostty, "Info.plist"), "")
  await writeFile(join(ghostty, ".codevisor-stamp"), "stamp-1\n")
  const environment = {
    PATH: `${bin}:${process.env.PATH ?? ""}`,
    CODEVISOR_NET_ARTIFACTS_ROOT: join(root, "net"),
    CODEVISOR_GHOSTTY_ARTIFACTS_ROOT: join(root, "ghostty")
  }
  return {
    repoRoot,
    environment,
    ghostty,
    calls: async () => (await readFile(log, "utf8")).trim().split("\n")
  }
}

it("installs dependencies and prepares the native frameworks each build needs", async () => {
  const { repoRoot, environment, ghostty, calls } = await fixture()

  await bootstrapDevelopment(repoRoot, { environment })
  expect(await calls()).toEqual(["bun install --frozen-lockfile", "turbo build:swift"])

  await bootstrapDevelopment(repoRoot, { environment, ghosttyKit: true })
  expect(await readlink(ghostty)).toMatch(/stamp-1\/GhosttyKit\.xcframework$/)
})
