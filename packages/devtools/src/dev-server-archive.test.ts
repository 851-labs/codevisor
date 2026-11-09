import { execFileSync } from "node:child_process"
import { createHash } from "node:crypto"
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it, vi } from "vitest"

import { captureCommand, runCommand } from "./commands.ts"
import { ensureDevServerArchive, serverInputsKey } from "./dev-server-archive.ts"

const cleanups: Array<() => Promise<unknown>> = []
afterEach(async () => {
  await Promise.all(cleanups.splice(0).map((cleanup) => cleanup()))
})

const scratch = async (prefix: string) => {
  const directory = await mkdtemp(join(tmpdir(), prefix))
  cleanups.push(() => rm(directory, { recursive: true, force: true }))
  return directory
}

const script = async (path: string, body: string) => {
  await writeFile(path, `#!/bin/sh\n${body}\n`)
  await chmod(path, 0o755)
}

const releaseRepo = async () => {
  const repoRoot = await scratch("codevisor-archive-repo-")
  await mkdir(join(repoRoot, "scripts/release"), { recursive: true })
  await mkdir(join(repoRoot, "packages"), { recursive: true })
  await writeFile(join(repoRoot, ".node-version"), "24.0.0\n")
  await script(join(repoRoot, "scripts/release/detect-target.sh"), "echo darwin-arm64")
  await script(join(repoRoot, "scripts/release/package-server-js.sh"), 'echo js > "$1"')
  await script(
    join(repoRoot, "scripts/release/build-server-archive.sh"),
    'test -f "$CODEVISOR_PREBUILT_SERVER_JS" && echo "$CODEVISOR_RELEASE_NODE" > "$2/codevisor-server-$3.tar.gz"'
  )
  return repoRoot
}

const fakeHome = async () => {
  const home = await scratch("codevisor-archive-home-")
  vi.stubEnv("HOME", home)
  return home
}

describe("ensureDevServerArchive", () => {
  it("builds the archive with the release Node and records its inputs", async () => {
    const repoRoot = await releaseRepo()
    const home = await fakeHome()
    const node = join(home, ".codevisor-development/artifacts/node/node-v24.0.0-darwin-arm64")
    await mkdir(join(node, "bin"), { recursive: true })
    await writeFile(join(node, "bin/node"), "")
    const archiveRoot = join(repoRoot, "archives")

    const archive = await ensureDevServerArchive({ repoRoot, archiveRoot })

    expect(archive).toBe(join(archiveRoot, "codevisor-server-darwin-arm64.tar.gz"))
    expect((await readFile(archive, "utf8")).trim()).toBe(join(node, "bin/node"))
    expect(await readFile(join(archiveRoot, "inputs.sha256"), "utf8")).toBe(
      await serverInputsKey(repoRoot, "darwin-arm64")
    )
  })

  it("downloads and verifies the release Node when it's missing", async () => {
    const repoRoot = await releaseRepo()
    const home = await fakeHome()
    const tarball = await nodeTarball("node-v24.0.0-darwin-arm64")
    const checksums = `${createHash("sha256").update(tarball).digest("hex")}  node-v24.0.0-darwin-arm64.tar.gz\n`
    vi.stubGlobal("fetch", async (url: string) =>
      url.endsWith(".tar.gz") ? new Response(new Uint8Array(tarball)) : new Response(checksums)
    )

    await ensureDevServerArchive({ repoRoot, archiveRoot: join(repoRoot, "archives") })

    expect(
      await readFile(
        join(home, ".codevisor-development/artifacts/node/node-v24.0.0-darwin-arm64/bin/node"),
        "utf8"
      )
    ).toBe("node")
  })

  it("refuses a Node download that doesn't match its published checksum", async () => {
    const repoRoot = await releaseRepo()
    await fakeHome()
    const tarball = await nodeTarball("node-v24.0.0-darwin-arm64")
    vi.stubGlobal("fetch", async (url: string) =>
      url.endsWith(".tar.gz")
        ? new Response(new Uint8Array(tarball))
        : new Response("0000  node-v24.0.0-darwin-arm64.tar.gz\n")
    )

    await expect(
      ensureDevServerArchive({ repoRoot, archiveRoot: join(repoRoot, "archives") })
    ).rejects.toThrow(/published SHA-256/)
  })

  it("reports a failed download", async () => {
    const repoRoot = await releaseRepo()
    await fakeHome()
    vi.stubGlobal("fetch", async () => new Response("", { status: 404 }))

    await expect(
      ensureDevServerArchive({ repoRoot, archiveRoot: join(repoRoot, "archives") })
    ).rejects.toThrow(/answered 404/)
  })
})

describe("standalone commands", () => {
  it("runs and captures commands and reports their failures", async () => {
    await runCommand(process.execPath, ["-e", ""])
    await expect(runCommand(process.execPath, ["-e", "process.exit(2)"])).rejects.toThrow(
      /failed \(code 2\)/
    )
    expect(await captureCommand(process.execPath, ["-e", "process.stdout.write('out')"])).toBe(
      "out"
    )
    await expect(captureCommand(process.execPath, ["-e", "process.exit(3)"])).rejects.toThrow(
      /failed \(code 3\)/
    )
  })
})

async function nodeTarball(name: string): Promise<Buffer> {
  const directory = await scratch("codevisor-node-tarball-")
  await mkdir(join(directory, name, "bin"), { recursive: true })
  await writeFile(join(directory, name, "bin/node"), "node")
  execFileSync("tar", ["-czf", join(directory, "node.tar.gz"), "-C", directory, name])
  return readFile(join(directory, "node.tar.gz"))
}
