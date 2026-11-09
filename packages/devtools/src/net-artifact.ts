import { createHash } from "node:crypto"
import { existsSync, readFileSync } from "node:fs"
import {
  mkdir,
  readdir,
  readFile,
  readlink,
  rename,
  rm,
  stat,
  symlink,
  writeFile
} from "node:fs/promises"
import { homedir } from "node:os"
import { dirname, join, relative } from "node:path"

import { withArtifactLock } from "./artifact-lock.ts"
import { runCommand } from "./commands.ts"
import type { ContainerEngine } from "./container-engine.ts"
import type { NetArtifacts } from "./dev-net.ts"
import { pathExists } from "./files.ts"

type Environment = Readonly<Record<string, string | undefined>>

export interface RelayAsset {
  readonly url: string
  readonly sha256: string
}

export interface NetLock {
  readonly linuxGlibc: string
  readonly certbot: string
  readonly relay: {
    readonly version: string
    readonly assets: Readonly<Record<string, RelayAsset>>
  }
}

const legacyBuildName = /^[0-9a-f]{16}$/
const legacyBuildRetentionMs = 7 * 24 * 60 * 60 * 1000

export const netRoot = (repoRoot: string): string => join(repoRoot, "packages", "net")
export const netNativeRoot = (repoRoot: string): string => join(netRoot(repoRoot), "native")
export const hostTarget = (
  platform: string = process.platform,
  arch: string = process.arch
): string => `${platform}-${arch}`

export function netArtifactsRoot(environment: Environment = process.env): string {
  return (
    environment.CODEVISOR_NET_ARTIFACTS_ROOT ??
    join(homedir(), ".codevisor-development", "artifacts", "net")
  )
}

export function netArtifacts(
  repoRoot: string,
  environment: Environment = process.env
): NetArtifacts {
  return {
    ensureNodeAddon: () => ensureNodeAddon(repoRoot, environment),
    ensureLinuxNodeAddon: (engine) =>
      ensureLinuxNodeAddon(repoRoot, engine, process.arch, environment),
    ensureRelayBinary: () => ensureRelayBinary(repoRoot, environment)
  }
}

export async function rustToolchain(repoRoot: string): Promise<string> {
  const channel = /^channel\s*=\s*"([^"]+)"/m.exec(
    await readFile(join(repoRoot, "rust-toolchain.toml"), "utf8")
  )?.[1]
  if (channel === undefined) throw new Error("rust-toolchain.toml has no channel")

  return channel
}

export async function readNetLock(repoRoot: string): Promise<NetLock> {
  const lock: unknown = JSON.parse(
    await readFile(join(repoRoot, "scripts", "net-build.lock.json"), "utf8")
  )
  if (!isNetLock(lock))
    throw new Error("scripts/net-build.lock.json is missing its relay, glibc, or certbot pins")

  return lock
}

export function relayBuildArguments(lock: NetLock): Array<string> {
  const asset = lock.relay.assets["linux-x64"]
  if (asset === undefined) throw new Error("no pinned iroh-relay build for linux-x64")

  return [
    `export IROH_RELAY_URL='${asset.url}'`,
    `export IROH_RELAY_SHA256='${asset.sha256}'`,
    `export CERTBOT_VERSION='${lock.certbot}'`
  ]
}

export async function netSourceStamp(repoRoot: string): Promise<string> {
  const files = [
    join(repoRoot, "scripts", "net-build.lock.json"),
    join(repoRoot, "scripts", "build-net-swift.sh")
  ]
  const walk = async (directory: string): Promise<void> => {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      if (entry.name === "target" || entry.name === "native" || entry.name === "node_modules")
        continue
      const path = join(directory, entry.name)
      if (entry.isDirectory()) await walk(path)
      else if (/\.(rs|toml|lock|udl|h|modulemap)$/.test(entry.name)) files.push(path)
    }
  }
  await walk(netRoot(repoRoot))

  const hash = createHash("sha256")
  for (const file of files.toSorted(byCodeUnit)) {
    hash.update(relative(repoRoot, file))
    hash.update("\0")
    hash.update(await readFile(file))
    hash.update("\0")
  }
  return hash.digest("hex").slice(0, 16)
}

export const rustupProxyDirectories = (home: string = homedir()): Array<string> => [
  join(home, ".cargo", "bin"),
  "/opt/homebrew/opt/rustup/bin",
  "/usr/local/opt/rustup/bin"
]

export async function findRustup(
  directories: ReadonlyArray<string> = rustupProxyDirectories()
): Promise<string | undefined> {
  for (const directory of directories) {
    if (
      (await pathExists(join(directory, "rustup"))) &&
      (await pathExists(join(directory, "cargo")))
    )
      return directory
  }
  return undefined
}

export async function cargoEnvironment(
  repoRoot: string,
  environment: Environment = process.env,
  directories: ReadonlyArray<string> = rustupProxyDirectories()
): Promise<NodeJS.ProcessEnv> {
  const directory = await findRustup(directories)
  if (directory === undefined) {
    throw new Error(
      "The tunnel's native code builds with rustup. Install it (brew install rustup, or https://rustup.rs); the Rust version is pinned in rust-toolchain.toml."
    )
  }
  const rust = await rustToolchain(repoRoot)
  const cargo = {
    ...environment,
    PATH: `${directory}:${environment.PATH ?? ""}`,
    RUSTUP_TOOLCHAIN: rust
  }
  await runCommand(
    join(directory, "rustup"),
    ["toolchain", "install", rust, "--profile", "minimal"],
    { env: cargo }
  )
  return cargo
}

export async function ensureNodeAddon(
  repoRoot: string,
  environment: Environment = process.env
): Promise<string> {
  const target = hostTarget()
  await runNetTask(repoRoot, `build:node:${target}`, environment)
  return join(netNativeRoot(repoRoot), target, "codevisor_net.node")
}

export async function ensureLinuxNodeAddon(
  repoRoot: string,
  engine: ContainerEngine,
  arch: string = process.arch,
  environment: Environment = process.env
): Promise<string> {
  const target = `linux-${arch}`
  await runNetTask(repoRoot, `build:node:${target}`, {
    ...environment,
    CODEVISOR_CONTAINER_ENGINE: engine
  })
  return join(netNativeRoot(repoRoot), target, "codevisor_net.node")
}

export async function ensureRelayBinary(
  repoRoot: string,
  environment: Environment = process.env
): Promise<string> {
  const lock = await readNetLock(repoRoot)
  const target = hostTarget()
  const asset = lock.relay.assets[target]
  if (asset === undefined) throw new Error(`no pinned iroh-relay build for ${target}`)

  const binary = join(
    netArtifactsRoot(environment),
    `relay-${lock.relay.version}`,
    target,
    "iroh-relay"
  )
  if (await pathExists(binary)) return binary

  await withArtifactLock(`${binary}.lock`, async () => {
    if (await pathExists(binary)) return

    console.log(`Downloading iroh-relay ${lock.relay.version} (${target})`)
    const response = await fetch(asset.url)
    if (!response.ok) throw new Error(`iroh-relay download failed: HTTP ${response.status}`)
    const archive = Buffer.from(await response.arrayBuffer())
    const digest = createHash("sha256").update(archive).digest("hex")
    if (digest !== asset.sha256)
      throw new Error(`iroh-relay checksum mismatch: expected ${asset.sha256}, got ${digest}`)

    const staging = `${dirname(binary)}.staging`
    await rm(staging, { recursive: true, force: true })
    await mkdir(staging, { recursive: true })
    await writeFile(join(staging, "relay.tar.gz"), archive)
    await runCommand("tar", ["-xzf", "relay.tar.gz", "./iroh-relay"], { cwd: staging })
    await mkdir(dirname(binary), { recursive: true })
    await rename(join(staging, "iroh-relay"), binary)
    await rm(staging, { recursive: true, force: true })
  })
  return binary
}

export async function ensureSwiftFramework(
  repoRoot: string,
  environment: Environment = process.env
): Promise<string> {
  await runNetTask(repoRoot, "build:swift", environment)
  const built = join(netNativeRoot(repoRoot), "apple")
  const link = join(repoRoot, "packages", "swift", "Frameworks", "CodevisorNetFFI.xcframework")
  await pointLinkAt(link, relative(dirname(link), join(built, "CodevisorNetFFI.xcframework")))
  await copyIfChanged(
    join(built, "codevisor_net_ffi.swift"),
    join(
      repoRoot,
      "packages/swift/CodevisorNet/Sources/CodevisorNet/Generated/codevisor_net_ffi.swift"
    )
  )
  return link
}

async function runNetTask(repoRoot: string, task: string, environment: Environment): Promise<void> {
  await discardLegacyBuilds(environment)
  const [command, args] = turboCommand(repoRoot, task)
  await withArtifactLock(join(netNativeRoot(repoRoot), `.${task.replaceAll(":", "-")}.lock`), () =>
    runCommand(command, args, { cwd: repoRoot, env: environment })
  )
}

function turboCommand(repoRoot: string, task: string): [string, Array<string>] {
  const args = ["run", task, "--filter=@codevisor/net", "--output-logs=errors-only"]
  const installed = join(repoRoot, "node_modules", ".bin", "turbo")
  if (existsSync(installed)) return [installed, args]

  return ["npx", ["--yes", `turbo@${pinnedTurbo(repoRoot)}`, ...args]]
}

function pinnedTurbo(repoRoot: string): string {
  const manifest: unknown = JSON.parse(readFileSync(join(repoRoot, "package.json"), "utf8"))
  const turbo =
    isRecord(manifest) && isRecord(manifest.devDependencies)
      ? manifest.devDependencies.turbo
      : undefined
  if (typeof turbo !== "string") throw new Error("package.json does not pin turbo")

  return turbo
}

async function discardLegacyBuilds(environment: Environment): Promise<void> {
  const root = netArtifactsRoot(environment)
  const names = (await readdir(root).catch(() => [])).filter((name) => legacyBuildName.test(name))
  await Promise.all(names.map((name) => discardIfUnused(join(root, name))))
}

async function discardIfUnused(path: string): Promise<void> {
  const info = await stat(path).catch(() => undefined)
  if (info === undefined || Date.now() - info.mtimeMs < legacyBuildRetentionMs) return

  await rm(path, { recursive: true, force: true })
}

async function pointLinkAt(link: string, target: string): Promise<void> {
  if ((await readlink(link).catch(() => undefined)) === target) return

  await mkdir(dirname(link), { recursive: true })
  await rm(link, { recursive: true, force: true })
  await symlink(target, link)
}

async function copyIfChanged(source: string, destination: string): Promise<void> {
  const contents = await readFile(source, "utf8")
  if ((await readFile(destination, "utf8").catch(() => "")) === contents) return

  await mkdir(dirname(destination), { recursive: true })
  await writeFile(destination, contents)
}

function byCodeUnit(a: string, b: string): number {
  if (a < b) return -1
  return a > b ? 1 : 0
}

function isNetLock(value: unknown): value is NetLock {
  return (
    isRecord(value) &&
    typeof value.linuxGlibc === "string" &&
    typeof value.certbot === "string" &&
    isRecord(value.relay) &&
    typeof value.relay.version === "string" &&
    isRecord(value.relay.assets) &&
    Object.values(value.relay.assets).every(
      (asset) =>
        isRecord(asset) && typeof asset.url === "string" && typeof asset.sha256 === "string"
    )
  )
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object"
}
