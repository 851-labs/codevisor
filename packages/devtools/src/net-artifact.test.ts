import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { createHash } from "node:crypto"
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import {
  chmod,
  mkdir,
  readdir,
  readFile,
  readlink,
  stat,
  utimes,
  writeFile
} from "node:fs/promises"
import { createServer } from "node:http"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { onTestFinished, test, vi } from "vitest"

import { STORE_RETENTION_MS } from "./apfs-clone.ts"
import {
  cargoEnvironment,
  ensureNodeAddon,
  ensureRelayBinary,
  ensureSwiftFramework,
  findRustup,
  hostTarget,
  netArtifacts,
  netArtifactsRoot,
  netBuildCache,
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

interface FakeRepoOptions {
  readonly relayURL?: string
  readonly relaySha?: string
  readonly turboLog?: string
  readonly buildGate?: BuildGate
}

const gateDeadlockGuardMs = 20_000

interface BuildGate {
  readonly started: string
  readonly release: string
}

function heldBuildGate(root: string): BuildGate {
  const gate = { started: join(root, "build-started"), release: join(root, "build-release") }
  execFileSync("mkfifo", [gate.started, gate.release])
  return gate
}

async function fakeRepo(root: string, options: FakeRepoOptions = {}) {
  const { relayURL = "http://127.0.0.1:9/relay.tar.gz", relaySha = "0".repeat(64) } = options
  const turboLog = options.turboLog ?? join(root, "turbo.log")
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
  await writeFile(
    join(repoRoot, "node_modules/.bin/turbo"),
    fakeTurbo({ native: join(repoRoot, "packages/net/native"), turboLog, ...options })
  )
  await chmod(join(repoRoot, "node_modules/.bin/turbo"), 0o755)
  return {
    repoRoot,
    turboRuns: async () => (await readFile(turboLog, "utf8")).trim().split("\n")
  }
}

function fakeTurbo(fake: { native: string; turboLog: string; buildGate?: BuildGate }): string {
  return `#!${process.execPath}
const fs = require("node:fs")
const crypto = require("node:crypto")
const [, task, ...flags] = process.argv.slice(2)
const cache = flags.find((flag) => flag.startsWith("--cache-dir=")).slice("--cache-dir=".length)
const sources = fs.readFileSync("packages/net/src/lib.rs", "utf8")
const hash = crypto.createHash("sha256").update(task + sources).digest("hex").slice(0, 16)
const archive = cache + "/" + hash + ".tar.zst"
const cached = fs.existsSync(archive)
if (flags.includes("--dry=json")) {
  console.log(JSON.stringify({ tasks: [{ hash, cache: { status: cached ? "HIT" : "MISS" } }] }))
  process.exit(0)
}
const gate = ${JSON.stringify(fake.buildGate ?? null)}
const held = async () => {
  if (cached || gate === null) return
  setTimeout(() => process.exit(1), ${gateDeadlockGuardMs}).unref()
  await fs.promises.writeFile(gate.started, "building")
  await fs.promises.readFile(gate.release)
}
held().then(() => {
  fs.appendFileSync(${JSON.stringify(fake.turboLog)}, (cached ? "reused " : "built ") + task + "\\n")
  const out = ${JSON.stringify(fake.native)} + "/" + (task === "build:swift" ? "apple" : task.slice("build:node:".length))
  fs.mkdirSync(out + "/CodevisorNetFFI.xcframework", { recursive: true })
  fs.writeFileSync(out + "/codevisor_net_ffi.swift", "// generated " + sources)
  fs.writeFileSync(out + "/codevisor_net.node", "addon " + sources)
  fs.mkdirSync(cache, { recursive: true })
  fs.writeFileSync(archive, "")
  fs.writeFileSync(cache + "/" + hash + "-meta.json", "{}")
  process.exit(0)
})
`
}

test("the lock, toolchain, and relay build arguments are read from the repo", async () => {
  const root = mkdtempSync(join(tmpdir(), "net-artifact-"))
  onTestFinished(() => rmSync(root, { recursive: true, force: true }))
  const { repoRoot } = await fakeRepo(root, {
    relayURL: "https://example.test/relay.tar.gz",
    relaySha: "ab".repeat(32)
  })

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
  const { repoRoot, turboRuns } = await fakeRepo(root)
  const environment = { ...process.env, CODEVISOR_NET_ARTIFACTS_ROOT: join(root, "artifacts") }
  await mkdir(join(root, "artifacts/0123456789abcdef"), { recursive: true })
  const old = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000)
  await utimes(join(root, "artifacts/0123456789abcdef"), old, old)
  vi.spyOn(console, "log").mockImplementation(() => {})

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

  assert.deepEqual(await turboRuns(), [
    `built build:node:${hostTarget()}`,
    `built build:node:linux-${process.arch}`,
    "built build:swift",
    "reused build:swift"
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
    "// generated fn main() {}"
  )
  assert.deepEqual(await readdir(join(root, "artifacts")), ["turbo-cache"])
})

test("worktrees that need the same build share one: the second waits for the first, then reuses it", async () => {
  const root = mkdtempSync(join(tmpdir(), "net-artifact-"))
  onTestFinished(() => rmSync(root, { recursive: true, force: true }))
  const shared = { turboLog: join(root, "turbo.log"), buildGate: heldBuildGate(root) }
  const first = await fakeRepo(join(root, "first"), shared)
  const second = await fakeRepo(join(root, "second"), shared)
  const environment = { ...process.env, CODEVISOR_NET_ARTIFACTS_ROOT: join(root, "artifacts") }
  const secondIsWaiting = new Promise<void>((resolve) => {
    vi.spyOn(console, "log").mockImplementation((message: unknown) => {
      if (String(message).includes("waiting")) resolve()
    })
  })

  const addons = Promise.all([
    ensureNodeAddon(first.repoRoot, environment),
    ensureNodeAddon(second.repoRoot, environment)
  ])
  await readFile(shared.buildGate.started)
  await secondIsWaiting
  await writeFile(shared.buildGate.release, "finish")

  for (const addon of await addons)
    assert.equal(await readFile(addon, "utf8"), "addon fn main() {}")
  assert.deepEqual(await first.turboRuns(), [
    `built build:node:${hostTarget()}`,
    `reused build:node:${hostTarget()}`
  ])
})

test("a worktree with changed sources builds its own without waiting for or replacing another's", async () => {
  const root = mkdtempSync(join(tmpdir(), "net-artifact-"))
  onTestFinished(() => rmSync(root, { recursive: true, force: true }))
  const turboLog = join(root, "turbo.log")
  const buildGate = heldBuildGate(root)
  const held = await fakeRepo(join(root, "held"), { turboLog, buildGate })
  const changed = await fakeRepo(join(root, "changed"), { turboLog })
  await writeFile(join(changed.repoRoot, "packages/net/src/lib.rs"), "fn changed() {}")
  const environment = { ...process.env, CODEVISOR_NET_ARTIFACTS_ROOT: join(root, "artifacts") }
  vi.spyOn(console, "log").mockImplementation(() => {})

  const heldAddon = ensureNodeAddon(held.repoRoot, environment)
  await readFile(buildGate.started)
  const changedAddon = await ensureNodeAddon(changed.repoRoot, environment)
  await writeFile(buildGate.release, "finish")

  assert.equal(await readFile(changedAddon, "utf8"), "addon fn changed() {}")
  assert.equal(await readFile(await heldAddon, "utf8"), "addon fn main() {}")
  const archives = (await readdir(netBuildCache(environment))).filter((name) =>
    name.endsWith(".tar.zst")
  )
  assert.equal(archives.length, 2)
})

test("shared builds unused for the retention period are removed; the one in use is kept fresh", async () => {
  const root = mkdtempSync(join(tmpdir(), "net-artifact-"))
  onTestFinished(() => rmSync(root, { recursive: true, force: true }))
  const { repoRoot } = await fakeRepo(root)
  const environment = { ...process.env, CODEVISOR_NET_ARTIFACTS_ROOT: join(root, "artifacts") }
  const cache = netBuildCache(environment)
  vi.spyOn(console, "log").mockImplementation(() => {})
  await ensureNodeAddon(repoRoot, environment)
  const inUse = await readdir(cache)
  const expired = new Date(Date.now() - STORE_RETENTION_MS - 60_000)
  for (const name of [...inUse, "0123456789abcdef.tar.zst", "0123456789abcdef-meta.json"]) {
    await writeFile(join(cache, name), "")
    await utimes(join(cache, name), expired, expired)
  }

  await ensureNodeAddon(repoRoot, environment)

  assert.deepEqual((await readdir(cache)).toSorted(), inUse.toSorted())
  for (const name of inUse)
    assert.ok((await stat(join(cache, name))).mtimeMs > expired.getTime() + 60_000)
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

  const corrupt = await fakeRepo(join(root, "corrupt"), { relayURL: url })
  await assert.rejects(ensureRelayBinary(corrupt.repoRoot, environment), /checksum mismatch/)

  const { repoRoot } = await fakeRepo(join(root, "valid"), {
    relayURL: url,
    relaySha: createHash("sha256").update(archive).digest("hex")
  })
  const binary = await ensureRelayBinary(repoRoot, environment)
  assert.equal(await ensureRelayBinary(repoRoot, environment), binary)
  assert.equal(await readFile(binary, "utf8"), "relay binary")
  assert.equal(downloads, 2)
})

test("cargo needs rustup", async () => {
  await assert.rejects(cargoEnvironment("/repo", {}, []), /builds with rustup/)
})
