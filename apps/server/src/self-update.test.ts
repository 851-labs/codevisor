import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import {
  defaultInstallFsOperations,
  installRuntime,
  planRestart,
  resolveInstallRoot
} from "./self-update.js"

const temporaryRoots: Array<string> = []
const makeTemporaryRoot = (): string => {
  const root = mkdtempSync(join(tmpdir(), "codevisor-self-update-"))
  temporaryRoots.push(root)
  return root
}

const writeRuntime = (root: string, version: string): void => {
  mkdirSync(join(root, "bin"), { recursive: true })
  writeFileSync(join(root, "VERSION"), `${version}\n`)
  writeFileSync(join(root, "main.js"), `// ${version}`)
  writeFileSync(join(root, "bin", "node"), "#!/bin/sh\n")
}

afterEach(() => {
  for (const root of temporaryRoots.splice(0)) {
    rmSync(root, { recursive: true, force: true })
  }
})

describe("resolveInstallRoot", () => {
  it("resolves the directory of a packaged runtime entrypoint", () => {
    const root = makeTemporaryRoot()
    const install = join(root, "codevisor")
    mkdirSync(install)
    writeRuntime(install, "1.0.0")

    expect(resolveInstallRoot(join(install, "main.js"))).toBe(install)
  })

  it("rejects entrypoints that are not packaged runtime roots", () => {
    const root = makeTemporaryRoot()
    // A dev checkout dist dir: main.js exists but VERSION and bin/node don't.
    const dist = join(root, "dist")
    mkdirSync(dist)
    writeFileSync(join(dist, "main.js"), "// dev")

    expect(resolveInstallRoot(join(dist, "main.js"))).toBeUndefined()
    expect(resolveInstallRoot(undefined)).toBeUndefined()
    expect(resolveInstallRoot("")).toBeUndefined()
  })
})

describe("planRestart", () => {
  it("uses the system manager for root processes under systemd", () => {
    expect(planRestart({ INVOCATION_ID: "abc123" }, 0)).toEqual({
      kind: "systemd",
      unit: "codevisor-server.service",
      userManager: false
    })
  })

  it("uses the user manager for non-root processes under systemd", () => {
    expect(planRestart({ INVOCATION_ID: "abc123" }, 1000)).toEqual({
      kind: "systemd",
      unit: "codevisor-server.service",
      userManager: true
    })
  })

  it("hands off directly outside systemd", () => {
    expect(planRestart({}, 0)).toEqual({ kind: "handoff" })
    expect(planRestart({ INVOCATION_ID: "" }, 0)).toEqual({ kind: "handoff" })
  })
})

describe("installRuntime", () => {
  it("swaps the extracted runtime into the install root and cleans up", async () => {
    const root = makeTemporaryRoot()
    const install = join(root, "codevisor")
    mkdirSync(install)
    writeRuntime(install, "1.0.0")

    await installRuntime({
      installRoot: install,
      extract: (destination) => {
        writeRuntime(destination, "2.0.0")
        return Promise.resolve()
      }
    })

    expect(readFileSync(join(install, "VERSION"), "utf8")).toBe("2.0.0\n")
    expect(defaultInstallFsOperations.exists(`${install}.next`)).toBe(false)
    expect(defaultInstallFsOperations.exists(`${install}.previous`)).toBe(false)
  })

  it("keeps the old install when the extracted runtime is incomplete", async () => {
    const root = makeTemporaryRoot()
    const install = join(root, "codevisor")
    mkdirSync(install)
    writeRuntime(install, "1.0.0")

    await expect(
      installRuntime({
        installRoot: install,
        extract: (destination) => {
          // Missing bin/node: a truncated or malformed archive.
          writeFileSync(join(destination, "main.js"), "// broken")
          return Promise.resolve()
        }
      })
    ).rejects.toThrow(/incomplete/)

    expect(readFileSync(join(install, "VERSION"), "utf8")).toBe("1.0.0\n")
    expect(defaultInstallFsOperations.exists(`${install}.next`)).toBe(false)
  })

  it("restores the old install when the final rename fails", async () => {
    const root = makeTemporaryRoot()
    const install = join(root, "codevisor")
    mkdirSync(install)
    writeRuntime(install, "1.0.0")

    const renames: Array<[string, string]> = []
    await expect(
      installRuntime({
        installRoot: install,
        extract: (destination) => {
          writeRuntime(destination, "2.0.0")
          return Promise.resolve()
        },
        fs: {
          ...defaultInstallFsOperations,
          rename: (from, to) => {
            renames.push([from, to])
            if (to === install && from === `${install}.next`) {
              throw new Error("disk went away")
            }
            defaultInstallFsOperations.rename(from, to)
          }
        }
      })
    ).rejects.toThrow("disk went away")

    // Old root moved aside, swap failed, old root restored.
    expect(renames).toEqual([
      [install, `${install}.previous`],
      [`${install}.next`, install],
      [`${install}.previous`, install]
    ])
    expect(readFileSync(join(install, "VERSION"), "utf8")).toBe("1.0.0\n")
  })
})
