import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { createHash } from "node:crypto"
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { chmod, mkdir, readdir, readFile, readlink, utimes, writeFile } from "node:fs/promises"
import { createServer } from "node:http"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { onTestFinished, test, vi } from "vitest"

import {
  cargoEnvironment,
  ensureRelayBinary,
  ensureSwiftFramework,
  findRustup,
  hostTarget,
  netArtifacts,
  netArtifactsRoot,
  netSourceStamp,
  readNetLock,
  relayBuildArguments,
  rustToolchain,
  rustupProxyDirectories
} from "./net-artifact.ts"

const directory = (root: string, name: string, files: Array<string>) => {
  const path = join(root, name)
  mkdirSync(path, { recursive: true })
  for (const file of files) writeFileSync(join(path, file), "")
  return path
}

test("rustup is looked for in its installer's and Homebrew's locations, the installer's first", () => {
  assert.deepEqual(rustupProxyDirectories("/Users/me"), [
    "/Users/me/.cargo/bin",
    "/opt/homebrew/opt/rustup/bin",
    "/usr/local/opt/rustup/bin"
  ])
})

test("the first directory with both rustup and its cargo proxy wins; a lone cargo doesn't count", async () => {
  const root = mkdtempSync(join(tmpdir(), "net-rustup-"))
  try {
    const standalone = directory(root, "rust", ["cargo", "rustc"])
    const homebrew = directory(root, "rustup", ["rustup", "cargo", "rustc"])
    const installer = directory(root, "cargo-bin", ["rustup", "cargo"])
    assert.equal(await findRustup([standalone, homebrew]), homebrew)
    assert.equal(await findRustup([installer, homebrew]), installer)
    assert.equal(await findRustup([standalone]), undefined)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

async function fakeRepo(
  root: string,
  relayURL = "http://127.0.0.1:9/relay.tar.gz",
  relaySha = "0".repeat(64)
) {
  const repoRoot = join(root, "repo")
  await mkdir(join(repoRoot, "scripts"), { recursive: true })
  await mkdir(join(repoRoot, "packages/net/src"), { recursive: true })
  await mkdir(join(repoRoot, "node_modules/.bin"), { recursive: true })
  await writeFile(join(repoRoot, "rust-toolchain.toml"), '[toolchain]\nchannel = "1.98.1"\n')
  await writeFile(join(repoRoot, "scripts/build-net-swift.sh"), "")
  await writeFile(join(repoRoot, "packages/net/Cargo.toml"), "[package]")
  await writeFile(join(repoRoot, "packages/net/src/lib.rs"), "fn main() {}")
  await writeFile(
    join(repoRoot, "scripts/net-build.lock.json"),
    JSON.stringify({
      linuxGlibc: "2.28",
      certbot: "5.8.0",
      relay: {
        version: "1.2.0",
        assets: {
          [hostTarget()]: { url: relayURL, sha256: relaySha },
          "linux-x64": { url: relayURL, sha256: relaySha }
        }
      }
    })
  )
  const native = join(repoRoot, "packages/net/native")
  const tasks = join(root, "turbo.jsonl")
  await writeFile(
    join(repoRoot, "node_modules/.bin/turbo"),
    `#!${process.execPath}
const fs = require("node:fs")
const task = process.argv[3]
fs.appendFileSync(${JSON.stringify(tasks)}, task + "\\n")
const out = task === "build:swift" ? ${JSON.stringify(native)} + "/apple" : ${JSON.stringify(native)} + "/" + task.slice("build:node:".length)
fs.mkdirSync(out + "/CodevisorNetFFI.xcframework", { recursive: true })
fs.writeFileSync(out + "/codevisor_net_ffi.swift", "// generated " + task)
fs.writeFileSync(out + "/codevisor_net.node", "addon")
`
  )
  await chmod(join(repoRoot, "node_modules/.bin/turbo"), 0o755)
  return { repoRoot, tasks: async () => (await readFile(tasks, "utf8")).trim().split("\n") }
}

test("the lock, toolchain, and relay build arguments are read from the repo", async () => {
  const root = mkdtempSync(join(tmpdir(), "net-artifact-"))
  onTestFinished(() => rmSync(root, { recursive: true, force: true }))
  const { repoRoot } = await fakeRepo(root, "https://example.test/relay.tar.gz", "ab".repeat(32))

  assert.equal(await rustToolchain(repoRoot), "1.98.1")
  assert.deepEqual(relayBuildArguments(await readNetLock(repoRoot)), [
    "export IROH_RELAY_URL='https://example.test/relay.tar.gz'",
    `export IROH_RELAY_SHA256='${"ab".repeat(32)}'`,
    "export CERTBOT_VERSION='5.8.0'"
  ])
  assert.equal(netArtifactsRoot({ CODEVISOR_NET_ARTIFACTS_ROOT: "/shared/net" }), "/shared/net")
  assert.equal(hostTarget("darwin", "arm64"), "darwin-arm64")

  await writeFile(join(repoRoot, "scripts/net-build.lock.json"), "{}")
  await assert.rejects(readNetLock(repoRoot), /missing its relay/)
  await writeFile(join(repoRoot, "rust-toolchain.toml"), "[toolchain]\n")
  await assert.rejects(rustToolchain(repoRoot), /no channel/)
})

test("the source stamp covers native sources and the build pins, not build outputs", async () => {
  const root = mkdtempSync(join(tmpdir(), "net-artifact-"))
  onTestFinished(() => rmSync(root, { recursive: true, force: true }))
  const { repoRoot } = await fakeRepo(root)
  const stamp = await netSourceStamp(repoRoot)

  await mkdir(join(repoRoot, "packages/net/target"), { recursive: true })
  await writeFile(join(repoRoot, "packages/net/target/out.rs"), "ignored")
  await writeFile(join(repoRoot, "packages/net/README.md"), "ignored")
  assert.equal(await netSourceStamp(repoRoot), stamp)

  await writeFile(join(repoRoot, "packages/net/src/lib.rs"), "fn main() { changed() }")
  assert.notEqual(await netSourceStamp(repoRoot), stamp)
  assert.match(stamp, /^[0-9a-f]{16}$/)
})

test("native artifacts are built through turbo and the Swift framework is linked into the package", async () => {
  const root = mkdtempSync(join(tmpdir(), "net-artifact-"))
  onTestFinished(() => rmSync(root, { recursive: true, force: true }))
  const { repoRoot, tasks } = await fakeRepo(root)
  const environment = { ...process.env, CODEVISOR_NET_ARTIFACTS_ROOT: join(root, "artifacts") }
  await mkdir(join(root, "artifacts/0123456789abcdef"), { recursive: true })
  const old = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000)
  await utimes(join(root, "artifacts/0123456789abcdef"), old, old)

  const artifacts = netArtifacts(repoRoot, environment)
  assert.equal(
    await artifacts.ensureNodeAddon(),
    join(repoRoot, "packages/net/native", hostTarget(), "codevisor_net.node")
  )
  assert.equal(
    await artifacts.ensureLinuxNodeAddon("docker"),
    join(repoRoot, "packages/net/native", `linux-${process.arch}`, "codevisor_net.node")
  )
  const link = await ensureSwiftFramework(repoRoot, environment)
  await ensureSwiftFramework(repoRoot, environment)

  assert.deepEqual(await tasks(), [
    `build:node:${hostTarget()}`,
    `build:node:linux-${process.arch}`,
    "build:swift",
    "build:swift"
  ])
  assert.equal(await readlink(link), "../../net/native/apple/CodevisorNetFFI.xcframework")
  assert.equal(
    await readFile(
      join(
        repoRoot,
        "packages/swift/CodevisorNet/Sources/CodevisorNet/Generated/codevisor_net_ffi.swift"
      ),
      "utf8"
    ),
    "// generated build:swift"
  )
  assert.deepEqual(await readdir(join(root, "artifacts")), [])
})

test("the pinned relay is downloaded once, verified, and unpacked", async () => {
  const root = mkdtempSync(join(tmpdir(), "net-artifact-"))
  onTestFinished(() => rmSync(root, { recursive: true, force: true }))
  await mkdir(join(root, "relay"))
  await writeFile(join(root, "relay/iroh-relay"), "relay binary")
  execFileSync("tar", [
    "-czf",
    join(root, "relay.tar.gz"),
    "-C",
    join(root, "relay"),
    "./iroh-relay"
  ])
  const archive = await readFile(join(root, "relay.tar.gz"))
  let downloads = 0
  const server = createServer((_request, response) => {
    downloads += 1
    response.end(archive)
  })
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  onTestFinished(() => new Promise<void>((resolve) => server.close(() => resolve())))
  const address = server.address()
  if (address === null || typeof address === "string") throw new Error("expected a TCP address")
  const url = `http://127.0.0.1:${address.port}/relay.tar.gz`
  const environment = { CODEVISOR_NET_ARTIFACTS_ROOT: join(root, "artifacts") }
  vi.spyOn(console, "log").mockImplementation(() => {})

  const corrupt = await fakeRepo(join(root, "corrupt"), url)
  await assert.rejects(ensureRelayBinary(corrupt.repoRoot, environment), /checksum mismatch/)

  const { repoRoot } = await fakeRepo(
    join(root, "valid"),
    url,
    createHash("sha256").update(archive).digest("hex")
  )
  const binary = await ensureRelayBinary(repoRoot, environment)
  assert.equal(await ensureRelayBinary(repoRoot, environment), binary)
  assert.equal(await readFile(binary, "utf8"), "relay binary")
  assert.equal(downloads, 2)
})

test("cargo needs rustup", async () => {
  await assert.rejects(cargoEnvironment("/repo", {}, []), /builds with rustup/)
})
