import { createHash } from "node:crypto"
import { access, mkdir, mkdtemp, readdir, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import {
  containerToolchain,
  isSupportedContainer,
  parseContainerVersion,
  type ContainerInstallDeps,
  type ContainerRelease
} from "./apple-container-install.js"

const scratch: string[] = []
const pkg = Buffer.from("signed container installer")
const release: ContainerRelease = {
  version: "1.3.1",
  url: "https://example.invalid/1.3.1/container.pkg",
  sha256: createHash("sha256").update(pkg).digest("hex")
}

const directory = async (): Promise<string> => {
  const path = await mkdtemp(join(tmpdir(), "container-install-"))
  scratch.push(path)
  return path
}

const exists = async (path: string): Promise<boolean> =>
  access(path).then(
    () => true,
    () => false
  )

const expandPayload = async (_pkg: string, target: string): Promise<void> => {
  await mkdir(join(target, "Payload", "bin"), { recursive: true })
  await writeFile(join(target, "Payload", "bin", "container"), "#!/bin/sh\n")
}

const depsFor = (overrides: Partial<ContainerInstallDeps> = {}) => {
  const downloads: string[] = []
  const deps: ContainerInstallDeps = {
    candidates: ["/nonexistent/codevisor-test/container"],
    version: async (binary) => ((await exists(binary)) ? "1.3.1" : undefined),
    download: (url) => {
      downloads.push(url)
      return Promise.resolve(pkg)
    },
    expand: expandPayload,
    ...overrides
  }
  return { deps, downloads }
}

const attempt = async (overrides: Partial<ContainerInstallDeps>) =>
  containerToolchain(await directory(), depsFor(overrides).deps, release)
    .install(() => undefined)
    .catch((cause: unknown) => (cause instanceof Error ? cause.message : String(cause)))

afterEach(async () => {
  await Promise.all(scratch.splice(0).map((path) => rm(path, { recursive: true, force: true })))
})

describe("Apple container install", () => {
  it("uses a container the user already has, before any managed copy", async () => {
    const versions: string[] = []
    const { deps, downloads } = depsFor({
      candidates: ["/missing/container", "/opt/homebrew/bin/container"],
      version: (binary) => {
        versions.push(binary)
        return Promise.resolve(binary.startsWith("/opt") ? "1.6.1" : undefined)
      }
    })
    const toolchain = containerToolchain(await directory(), deps, release)

    await toolchain.install(() => undefined)

    expect(await toolchain.locate()).toEqual({
      binary: "/opt/homebrew/bin/container",
      version: "1.6.1"
    })
    expect(versions).toEqual(["/missing/container", "/opt/homebrew/bin/container"])
    expect(downloads).toEqual([])
  })

  it("downloads, verifies and unpacks Apple's pinned release into the tools folder, once", async () => {
    const tools = await directory()
    await mkdir(join(tools, "container", "1.2.0"), { recursive: true })
    const { deps, downloads } = depsFor()
    const toolchain = containerToolchain(tools, deps, release)
    const logs: string[] = []

    await Promise.all([
      toolchain.install((line) => logs.push(line)),
      toolchain.install(() => undefined)
    ])

    expect(downloads).toEqual([release.url])
    expect(await toolchain.locate()).toEqual({
      binary: join(tools, "container", "1.3.1", "bin", "container"),
      version: "1.3.1"
    })
    expect(await readdir(join(tools, "container"))).toEqual(["1.3.1"])
    expect(logs).toEqual([
      "Downloading Apple's container 1.3.1",
      `Unpacking container into ${join(tools, "container")}`,
      "Installed container 1.3.1"
    ])
  })

  it("refuses a download that fails or doesn't match its checksum, and an unpack that fails or can't run", async () => {
    expect(await attempt({ download: () => Promise.reject(new Error("HTTP 503")) })).toBe(
      "Couldn't download Apple's container tool: HTTP 503"
    )
    expect(await attempt({ download: () => Promise.reject("offline") })).toBe(
      "Couldn't download Apple's container tool: offline"
    )
    expect(await attempt({ download: () => Promise.resolve(Buffer.from("tampered")) })).toBe(
      "The container download didn't match its checksum"
    )
    expect(await attempt({ expand: () => Promise.reject(new Error("not a pkg")) })).toBe(
      "Couldn't unpack the container installer"
    )
    expect(await attempt({ version: () => Promise.resolve(undefined) })).toBe(
      "container was unpacked but can't run"
    )
  })

  it("reads container's version and accepts 1.3 and later 1.x releases", () => {
    expect(
      parseContainerVersion("container CLI version 1.3.1 (build: release, commit: a9a62e2)\n")
    ).toBe("1.3.1")
    expect(parseContainerVersion("container: command not found")).toBeUndefined()
    expect(["1.3.0", "1.6.1", "1.10.0"].map(isSupportedContainer)).toEqual([true, true, true])
    expect(["0.9.0", "1.2.9", "2.0.0", "garbage"].map(isSupportedContainer)).toEqual([
      false,
      false,
      false,
      false
    ])
  })
})
