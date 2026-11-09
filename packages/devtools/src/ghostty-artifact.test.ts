import assert from "node:assert/strict"
import { execFile } from "node:child_process"
import { createHash } from "node:crypto"
import {
  chmod,
  cp,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readlink,
  rm,
  writeFile
} from "node:fs/promises"
import { createServer } from "node:http"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import { onTestFinished, test } from "vitest"

import {
  buildGhosttyFramework,
  ensureGhosttyFramework,
  GHOSTTY_SLICES,
  ghosttyArtifactsRoot,
  ghosttyCachedFramework,
  validFramework
} from "./ghostty-artifact.ts"

const execFileAsync = promisify(execFile)
const buildGhosttyScript = new URL("../../../apps/macos/scripts/build-ghostty.sh", import.meta.url)

async function scratch() {
  const root = await mkdtemp(join(tmpdir(), "codevisor-ghostty-test-"))
  onTestFinished(() => rm(root, { recursive: true, force: true }))
  return root
}

async function writeFramework(framework: string, stamp: string) {
  for (const slice of GHOSTTY_SLICES) {
    await mkdir(join(framework, slice, "Headers/GhosttyKit"), { recursive: true })
    await writeFile(join(framework, slice, "Headers/GhosttyKit/ghostty.h"), "header")
    await writeFile(join(framework, slice, "Headers/GhosttyKit/module.modulemap"), "module")
    await writeFile(join(framework, slice, "ghostty-internal.a"), "archive")
  }
  await writeFile(join(framework, "Info.plist"), "plist")
  await writeFile(join(framework, ".codevisor-stamp"), `${stamp}\n`)
}

async function fakeCheckout(root: string, stamp: string, build = "exit 1") {
  const repoRoot = join(root, "repo")
  const script = join(repoRoot, "apps/macos/scripts/build-ghostty.sh")
  await mkdir(join(repoRoot, "apps/macos/scripts"), { recursive: true })
  await writeFile(
    script,
    `#!/bin/sh\nif [ "$1" = "--print-stamp" ]; then echo ${stamp}; exit 0; fi\n${build}\n`
  )
  await chmod(script, 0o755)
  return repoRoot
}

test("the artifacts root honors CODEVISOR_GHOSTTY_ARTIFACTS_ROOT", () => {
  const root = ghosttyArtifactsRoot({ CODEVISOR_GHOSTTY_ARTIFACTS_ROOT: "/shared/ghostty" })
  assert.equal(root, "/shared/ghostty")
  assert.equal(
    ghosttyCachedFramework(root, "stamp"),
    "/shared/ghostty/stamp/GhosttyKit.xcframework"
  )
})

test("Ghostty build stamp is independent of the checkout path", async () => {
  const root = await scratch()
  const stamps: Array<string> = []
  for (const checkout of ["first", "nested/second"]) {
    const script = join(root, checkout, "apps/macos/scripts/build-ghostty.sh")
    await mkdir(join(root, checkout, "apps/macos/scripts"), { recursive: true })
    await cp(buildGhosttyScript, script)
    const { stdout } = await execFileAsync("/bin/bash", [script, "--print-stamp"])
    stamps.push(stdout.trim())
  }

  assert.equal(stamps[0], stamps[1])
})

test("Ghostty framework validation requires the expected stamp and structure", async () => {
  const framework = join(await scratch(), "GhosttyKit.xcframework")
  await writeFramework(framework, "current")

  assert.equal(await validFramework(framework, "current"), true)
  assert.equal(await validFramework(framework, "stale"), false)
  await rm(join(framework, "ios-arm64/Headers/GhosttyKit/module.modulemap"))
  assert.equal(await validFramework(framework, "current"), false)
  await writeFramework(framework, "current")
  await rm(join(framework, "ios-arm64"), { recursive: true })
  assert.equal(await validFramework(framework, "current"), false)
})

test("an existing local build seeds the shared cache and the checkout links to it", async () => {
  const root = await scratch()
  const repoRoot = await fakeCheckout(root, "stamp-a")
  const environment = { CODEVISOR_GHOSTTY_ARTIFACTS_ROOT: join(root, "artifacts") }
  const local = join(repoRoot, "apps/macos/Frameworks/GhosttyKit.xcframework")
  await writeFramework(local, "stamp-a")

  const result = await ensureGhosttyFramework(repoRoot, environment)

  assert.equal(
    result.cachedFramework,
    ghosttyCachedFramework(environment.CODEVISOR_GHOSTTY_ARTIFACTS_ROOT, "stamp-a")
  )
  assert.equal(await validFramework(result.cachedFramework, "stamp-a"), true)
  assert.equal(await readlink(local), "../../../../artifacts/stamp-a/GhosttyKit.xcframework")
  assert.deepEqual(await ensureGhosttyFramework(repoRoot, environment), result)
})

test("an unpublished stamp falls back to building locally", async () => {
  const root = await scratch()
  const local = join(root, "repo/apps/macos/Frameworks/GhosttyKit.xcframework")
  const build = `mkdir -p "${local}" && for slice in ${GHOSTTY_SLICES.join(" ")}; do mkdir -p "${local}/$slice/Headers/GhosttyKit" && touch "${local}/$slice/Headers/GhosttyKit/ghostty.h" "${local}/$slice/Headers/GhosttyKit/module.modulemap" "${local}/$slice/ghostty-internal.a"; done && touch "${local}/Info.plist" && echo stamp-b > "${local}/.codevisor-stamp"`
  const repoRoot = await fakeCheckout(root, "stamp-b", build)
  const environment = {
    CODEVISOR_GHOSTTY_ARTIFACTS_ROOT: join(root, "artifacts"),
    CODEVISOR_GHOSTTY_ARTIFACT_ORIGIN: "http://127.0.0.1:9/"
  }

  const result = await ensureGhosttyFramework(repoRoot, environment)

  assert.equal(await validFramework(result.cachedFramework, "stamp-b"), true)
  assert.equal(await validFramework(local, "stamp-b"), true)
})

test("an intentional rebuild replaces the shared framework with the local build", async () => {
  const root = await scratch()
  const local = join(root, "repo/apps/macos/Frameworks/GhosttyKit.xcframework")
  const build = `rm -rf "${local}" && mkdir -p "${local}" && for slice in ${GHOSTTY_SLICES.join(" ")}; do mkdir -p "${local}/$slice/Headers/GhosttyKit" && touch "${local}/$slice/Headers/GhosttyKit/ghostty.h" "${local}/$slice/Headers/GhosttyKit/module.modulemap" "${local}/$slice/ghostty-internal.a"; done && touch "${local}/Info.plist" && echo stamp-d > "${local}/.codevisor-stamp"`
  const repoRoot = await fakeCheckout(root, "stamp-d", build)
  const environment = { CODEVISOR_GHOSTTY_ARTIFACTS_ROOT: join(root, "artifacts") }

  const result = await buildGhosttyFramework(repoRoot, environment)

  assert.equal(await validFramework(result.cachedFramework, "stamp-d"), true)
  assert.equal((await lstat(local)).isSymbolicLink(), true)
  await rm(local)
  await fakeCheckout(root, "stamp-d")
  await assert.rejects(buildGhosttyFramework(repoRoot, environment), /build-ghostty\.sh failed/)
})

test("a published stamp is downloaded, verified, and installed", async () => {
  const root = await scratch()
  const repoRoot = await fakeCheckout(root, "stamp-c")
  const published = join(root, "published")
  await writeFramework(join(published, "GhosttyKit.xcframework"), "stamp-c")
  const archive = join(root, "GhosttyKit.xcframework.tar.gz")
  await execFileAsync("tar", ["-czf", archive, "-C", published, "GhosttyKit.xcframework"])
  const bytes = await readFile(archive)
  const checksum = createHash("sha256").update(bytes).digest("hex")
  const requests: Array<string | undefined> = []
  const server = createServer((request, response) => {
    requests.push(request.url)
    response.end(
      request.url?.endsWith(".sha256") ? `${checksum}  GhosttyKit.xcframework.tar.gz\n` : bytes
    )
  })
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  onTestFinished(() => new Promise<void>((resolve) => server.close(() => resolve())))
  const address = server.address()
  if (address === null || typeof address === "string") throw new Error("expected a TCP address")

  const result = await ensureGhosttyFramework(repoRoot, {
    CODEVISOR_GHOSTTY_ARTIFACTS_ROOT: join(root, "artifacts"),
    CODEVISOR_GHOSTTY_ARTIFACT_ORIGIN: `http://127.0.0.1:${address.port}/ghostty/`
  })

  assert.equal(await validFramework(result.cachedFramework, "stamp-c"), true)
  assert.deepEqual(requests, [
    "/ghostty/stamp-c/GhosttyKit.xcframework.tar.gz.sha256",
    "/ghostty/stamp-c/GhosttyKit.xcframework.tar.gz"
  ])
})
