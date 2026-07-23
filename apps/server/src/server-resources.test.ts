import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  findServerResource,
  requireServerResource,
  serverResourceDirectories
} from "./server-resources.js"

const directories: string[] = []

afterEach(() => {
  vi.unstubAllEnvs()
  for (const directory of directories.splice(0)) {
    rmSync(directory, { force: true, recursive: true })
  }
})

const temporaryDirectory = (): string => {
  const directory = mkdtempSync(join(tmpdir(), "codevisor-server-resources-"))
  directories.push(directory)
  return directory
}

describe("server resources", () => {
  it("resolves packaged resources independently of the working directory", () => {
    const runtime = temporaryDirectory()
    const helper = join(runtime, "apps", "server", "resources", "computer-use-linux.py")
    mkdirSync(join(helper, ".."), { recursive: true })
    writeFileSync(helper, "# helper")

    expect(
      findServerResource("computer-use-linux.py", {
        moduleDirectory: runtime,
        workingDirectory: "/"
      })
    ).toBe(helper)
  })

  it("prefers an explicit resource directory over layout compatibility fallbacks", () => {
    const root = temporaryDirectory()
    const explicit = join(root, "explicit")
    const fallback = join(root, "runtime", "apps", "server", "resources")
    mkdirSync(explicit, { recursive: true })
    mkdirSync(fallback, { recursive: true })
    writeFileSync(join(explicit, "asset.txt"), "explicit")
    writeFileSync(join(fallback, "asset.txt"), "fallback")

    expect(
      findServerResource("asset.txt", {
        resourceDirectory: explicit,
        moduleDirectory: join(root, "runtime"),
        workingDirectory: "/"
      })
    ).toBe(join(explicit, "asset.txt"))
  })

  it("honors the production resource-root override and reports missing required assets", () => {
    const root = temporaryDirectory()
    vi.stubEnv("CODEVISOR_SERVER_RESOURCES", root)
    writeFileSync(join(root, "present.txt"), "present")

    expect(serverResourceDirectories({ moduleDirectory: "/", workingDirectory: "/" })[0]).toBe(root)
    expect(requireServerResource("present.txt", "test asset")).toBe(join(root, "present.txt"))
    expect(() => requireServerResource("missing.txt", "test asset")).toThrow("Missing test asset")
  })
})
