import { spawn } from "node:child_process"
import { createHash } from "node:crypto"
import { existsSync, readFileSync } from "node:fs"
import {
  access,
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
import process from "node:process"
import { fileURLToPath } from "node:url"

import { withArtifactLock } from "./artifact-lock.mjs"

export const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..")
export const netRoot = join(repoRoot, "packages", "net")
export const netNativeRoot = join(netRoot, "native")
const legacyBuildName = /^[0-9a-f]{16}$/
const legacyBuildRetentionMs = 7 * 24 * 60 * 60 * 1000

export const hostTarget = (platform = process.platform, arch = process.arch) =>
  `${platform}-${arch}`

export function netArtifactsRoot(environment = process.env) {
  return (
    environment.CODEVISOR_NET_ARTIFACTS_ROOT ??
    join(homedir(), ".codevisor-development", "artifacts", "net")
  )
}

export async function rustToolchain(root = repoRoot) {
  const channel = /^channel\s*=\s*"([^"]+)"/m.exec(
    await readFile(join(root, "rust-toolchain.toml"), "utf8")
  )?.[1]
  if (channel === undefined) throw new Error("rust-toolchain.toml has no channel")

  return channel
}

export async function readNetLock(root = repoRoot) {
  return JSON.parse(await readFile(join(root, "scripts", "net-build.lock.json"), "utf8"))
}

export async function netSourceStamp(root = repoRoot) {
  const hash = createHash("sha256")
  const files = [
    join(root, "scripts", "net-build.lock.json"),
    join(root, "scripts", "build-net-swift.sh")
  ]
  const walk = async (dir) => {
    for (const entry of await readdir(dir, { withFileTypes: true })) {
      if (entry.name === "target" || entry.name === "native" || entry.name === "node_modules")
        continue
      const path = join(dir, entry.name)
      if (entry.isDirectory()) await walk(path)
      else if (/\.(rs|toml|lock|udl|h|modulemap)$/.test(entry.name)) files.push(path)
    }
  }
  await walk(join(root, "packages", "net"))
  for (const file of files.toSorted(byCodeUnit)) {
    hash.update(relative(root, file))
    hash.update("\0")
    hash.update(await readFile(file))
    hash.update("\0")
  }
  return hash.digest("hex").slice(0, 16)
}

function byCodeUnit(a, b) {
  if (a < b) return -1
  return a > b ? 1 : 0
}

const exists = (path) =>
  access(path).then(
    () => true,
    () => false
  )

export function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: "inherit", ...options })
    child.on("error", reject)
    child.on("exit", (code) =>
      code === 0 ? resolve() : reject(new Error(`${command} ${args.join(" ")} exited ${code}`))
    )
  })
}

export const rustupProxyDirectories = (home = homedir()) => [
  join(home, ".cargo", "bin"),
  "/opt/homebrew/opt/rustup/bin",
  "/usr/local/opt/rustup/bin"
]

export async function findRustup(directories = rustupProxyDirectories()) {
  for (const directory of directories) {
    if ((await exists(join(directory, "rustup"))) && (await exists(join(directory, "cargo")))) {
      return directory
    }
  }
  return undefined
}

export async function cargoEnv(environment = process.env, directories = rustupProxyDirectories()) {
  const directory = await findRustup(directories)
  if (directory === undefined) {
    throw new Error(
      "The tunnel's native code builds with rustup. Install it (brew install rustup, or " +
        "https://rustup.rs); the Rust version is pinned in rust-toolchain.toml."
    )
  }
  const rust = await rustToolchain()
  const env = {
    ...environment,
    PATH: `${directory}:${environment.PATH ?? ""}`,
    RUSTUP_TOOLCHAIN: rust
  }
  await run(join(directory, "rustup"), ["toolchain", "install", rust, "--profile", "minimal"], {
    env
  })
  return env
}

export async function ensureNodeAddon(environment = process.env) {
  const target = hostTarget()
  await runNetTask(`build:node:${target}`, environment)
  return join(netNativeRoot, target, "codevisor_net.node")
}

export async function ensureLinuxNodeAddon(engine, arch = process.arch, environment = process.env) {
  const target = `linux-${arch}`
  await runNetTask(`build:node:${target}`, { ...environment, CODEVISOR_CONTAINER_ENGINE: engine })
  return join(netNativeRoot, target, "codevisor_net.node")
}

export async function ensureRelayBinary(environment = process.env) {
  const lock = await readNetLock()
  const target = hostTarget()
  const asset = lock.relay.assets[target]
  if (asset === undefined) throw new Error(`no pinned iroh-relay build for ${target}`)
  const binary = join(
    netArtifactsRoot(environment),
    `relay-${lock.relay.version}`,
    target,
    "iroh-relay"
  )
  if (await exists(binary)) return binary
  await withArtifactLock(`${binary}.lock`, async () => {
    if (await exists(binary)) return
    console.log(`Downloading iroh-relay ${lock.relay.version} (${target})`)
    const response = await fetch(asset.url)
    if (!response.ok) throw new Error(`iroh-relay download failed: HTTP ${response.status}`)
    const archive = Buffer.from(await response.arrayBuffer())
    const digest = createHash("sha256").update(archive).digest("hex")
    if (digest !== asset.sha256) {
      throw new Error(`iroh-relay checksum mismatch: expected ${asset.sha256}, got ${digest}`)
    }
    const staging = `${dirname(binary)}.staging`
    await rm(staging, { recursive: true, force: true })
    await mkdir(staging, { recursive: true })
    await writeFile(join(staging, "relay.tar.gz"), archive)
    await run("tar", ["-xzf", "relay.tar.gz", "./iroh-relay"], { cwd: staging })
    await mkdir(dirname(binary), { recursive: true })
    await rename(join(staging, "iroh-relay"), binary)
    await rm(staging, { recursive: true, force: true })
  })
  return binary
}

export async function ensureSwiftFramework(environment = process.env) {
  await runNetTask("build:swift", environment)
  const built = join(netNativeRoot, "apple")
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

async function runNetTask(task, environment) {
  await discardLegacyBuilds(environment)
  await withArtifactLock(join(netNativeRoot, `.${task.replaceAll(":", "-")}.lock`), () =>
    run(...turboCommand(task), { cwd: repoRoot, env: environment })
  )
}

function turboCommand(task) {
  const args = ["run", task, "--filter=@codevisor/net", "--output-logs=errors-only"]
  const installed = join(repoRoot, "node_modules", ".bin", "turbo")
  if (existsSync(installed)) return [installed, args]

  const { turbo } = JSON.parse(readFileSync(join(repoRoot, "package.json"), "utf8")).devDependencies
  return ["npx", ["--yes", `turbo@${turbo}`, ...args]]
}

async function discardLegacyBuilds(environment) {
  const root = netArtifactsRoot(environment)
  const names = (await readdir(root).catch(() => [])).filter((name) => legacyBuildName.test(name))
  await Promise.all(names.map((name) => discardIfUnused(join(root, name))))
}

async function discardIfUnused(path) {
  const info = await stat(path).catch(() => undefined)
  if (info === undefined || Date.now() - info.mtimeMs < legacyBuildRetentionMs) return

  await rm(path, { recursive: true, force: true })
}

async function pointLinkAt(link, target) {
  if ((await readlink(link).catch(() => undefined)) === target) return

  await mkdir(dirname(link), { recursive: true })
  await rm(link, { recursive: true, force: true })
  await symlink(target, link)
}

async function copyIfChanged(source, destination) {
  const contents = await readFile(source, "utf8")
  if ((await readFile(destination, "utf8").catch(() => "")) === contents) return

  await mkdir(dirname(destination), { recursive: true })
  await writeFile(destination, contents)
}

async function main(command) {
  switch (command) {
    case "stamp":
      console.log(await netSourceStamp())
      return
    case "ensure-node":
      console.log(await ensureNodeAddon())
      return
    case "ensure-relay":
      console.log(await ensureRelayBinary())
      return
    case "ensure-swift":
      console.log(await ensureSwiftFramework())
      return
    case "cargo":
      await run("cargo", process.argv.slice(3), { cwd: repoRoot, env: await cargoEnv() })
      return
    case "relay-build-args": {
      const lock = await readNetLock()
      const asset = lock.relay.assets["linux-x64"]
      console.log(`export IROH_RELAY_URL='${asset.url}'`)
      console.log(`export IROH_RELAY_SHA256='${asset.sha256}'`)
      console.log(`export CERTBOT_VERSION='${lock.certbot}'`)
      return
    }
    default:
      throw new Error(
        "usage: net-artifact.mjs <stamp|ensure-node|ensure-relay|ensure-swift|relay-build-args|cargo ARGS…>"
      )
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main(process.argv[2]).catch((error) => {
    console.error(error.message)
    process.exitCode = 1
  })
}
