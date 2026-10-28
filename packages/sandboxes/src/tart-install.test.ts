import { execFile } from "node:child_process"
import { createHash } from "node:crypto"
import { mkdir, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { promisify } from "node:util"

import { afterEach, describe, expect, it } from "vitest"

import { managedTart, systemTart, type TartRelease } from "./tart-install.js"

const execFileAsync = promisify(execFile)
const scratch: string[] = []

const directory = async (): Promise<string> => {
  const path = await mkdtemp(join(tmpdir(), "tart-install-"))
  scratch.push(path)
  return path
}

const archiveOf = async (files: Readonly<Record<string, string>>): Promise<Buffer> => {
  const source = await directory()
  for (const [path, contents] of Object.entries(files)) {
    await mkdir(dirname(join(source, path)), { recursive: true })
    await writeFile(join(source, path), contents, { mode: 0o755 })
  }
  const archive = join(await directory(), "tart.tar.gz")
  await execFileAsync("tar", ["-czf", archive, "-C", source, "."])
  return readFile(archive)
}

const tartArchive = (): Promise<Buffer> =>
  archiveOf({
    LICENSE: "FSL-1.1-ALv2\n",
    "tart.app/Contents/MacOS/tart": "#!/bin/sh\necho 2.41.1\n"
  })

const releaseOf = (archive: Buffer, version = "2.41.1"): TartRelease => ({
  version,
  url: `https://example.invalid/${version}/tart.tar.gz`,
  sha256: createHash("sha256").update(archive).digest("hex")
})

afterEach(async () => {
  await Promise.all(scratch.splice(0).map((path) => rm(path, { recursive: true, force: true })))
})

describe("Managed Tart", () => {
  it("downloads, verifies and unpacks the pinned release into the tools folder, once", async () => {
    const archive = await tartArchive()
    const tools = await directory()
    const downloads: string[] = []
    const lines: string[] = []
    const tart = managedTart(
      tools,
      (url) => {
        downloads.push(url)
        return Promise.resolve(archive)
      },
      releaseOf(archive)
    )
    const before = await tart.installed()

    await Promise.all([tart.install((line) => lines.push(line)), tart.install(() => undefined)])
    await tart.install(() => undefined)

    expect(before).toBe(false)
    expect(await tart.installed()).toBe(true)
    expect(tart.binary).toBe(join(tools, "tart", "2.41.1", "tart.app", "Contents", "MacOS", "tart"))
    expect(downloads).toEqual(["https://example.invalid/2.41.1/tart.tar.gz"])
    expect(lines).toEqual([
      "Downloading Tart 2.41.1",
      `Unpacking Tart into ${join(tools, "tart")}`,
      "Installed Tart 2.41.1"
    ])
    expect(await readdir(join(tools, "tart"))).toEqual(["2.41.1"])
  })

  it("replaces an older managed version", async () => {
    const archive = await tartArchive()
    const tools = await directory()
    await mkdir(join(tools, "tart", "2.30.0", "tart.app"), { recursive: true })
    await mkdir(join(tools, "tart", ".install-crashed"), { recursive: true })

    await managedTart(tools, () => Promise.resolve(archive), releaseOf(archive)).install(
      () => undefined
    )

    expect(await readdir(join(tools, "tart"))).toEqual(["2.41.1"])
  })

  it("refuses a download that doesn't match the pinned checksum and installs nothing", async () => {
    const archive = await tartArchive()
    const tools = await directory()
    const tart = managedTart(
      tools,
      () => Promise.resolve(Buffer.from("tampered")),
      releaseOf(archive)
    )

    await expect(tart.install(() => undefined)).rejects.toThrow(
      "The Tart download didn't match its checksum"
    )
    expect(await tart.installed()).toBe(false)
  })

  it("explains a failed download", async () => {
    const tart = managedTart(
      await directory(),
      () => Promise.reject(new Error("HTTP 503")),
      releaseOf(Buffer.from(""))
    )

    await expect(tart.install(() => undefined)).rejects.toThrow("Couldn't download Tart: HTTP 503")
    await expect(
      managedTart(
        await directory(),
        () => Promise.reject("socket hang up"),
        releaseOf(Buffer.from(""))
      ).install(() => undefined)
    ).rejects.toThrow("Couldn't download Tart: socket hang up")
  })

  it("refuses a download that isn't an archive, or an archive without a runnable Tart", async () => {
    const garbage = Buffer.from("not an archive")
    const licenseOnly = await archiveOf({ LICENSE: "FSL-1.1-ALv2\n" })
    const unreadable = managedTart(
      await directory(),
      () => Promise.resolve(garbage),
      releaseOf(garbage)
    )
    const empty = managedTart(
      await directory(),
      () => Promise.resolve(licenseOnly),
      releaseOf(licenseOnly)
    )

    await expect(unreadable.install(() => undefined)).rejects.toThrow(
      "Couldn't unpack the Tart download"
    )
    await expect(empty.install(() => undefined)).rejects.toThrow("Tart was unpacked but can't run")
  })

  it("treats an explicitly configured binary as already installed", async () => {
    const tart = systemTart("/opt/tart/bin/tart")

    await tart.install(() => undefined)

    expect(tart.binary).toBe("/opt/tart/bin/tart")
    expect(await tart.installed()).toBe(true)
  })
})
