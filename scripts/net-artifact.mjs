// Native pieces of the Codevisor tunnel (docs/plans/codevisor-tunnel.md):
//
// - the Node addon (`packages/net/native/<platform>-<arch>/codevisor_net.node`)
//   built from packages/net with cargo, cached per source stamp;
// - the pinned `iroh-relay` binary for local development relays, downloaded
//   from the URL + sha256 in scripts/net-build.lock.json (the same entry the
//   relay Docker image uses, so dev and production run identical bytes);
// - the Swift xcframework (`ensure-swift`), see scripts/build-net-swift.sh.
//
// Everything is cached under ~/.codevisor-development/artifacts/net and
// shared across worktrees with the same cross-process lock as Ghostty.
//
// Usage: node scripts/net-artifact.mjs <stamp|ensure-node|ensure-relay|ensure-swift|relay-build-args|cargo ARGS…>
import { spawn } from "node:child_process"
import { createHash } from "node:crypto"
import {
  access,
  copyFile,
  mkdir,
  readdir,
  readFile,
  readlink,
  rename,
  rm,
  symlink,
  writeFile
} from "node:fs/promises"
import { homedir } from "node:os"
import { dirname, join, relative } from "node:path"
import process from "node:process"
import { fileURLToPath } from "node:url"

import { withArtifactLock } from "./artifact-lock.mjs"

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..")
const netRoot = join(repoRoot, "packages", "net")

export const hostTarget = (platform = process.platform, arch = process.arch) =>
  `${platform}-${arch}`

export function netArtifactsRoot(environment = process.env) {
  return (
    environment.CODEVISOR_NET_ARTIFACTS_ROOT ??
    join(homedir(), ".codevisor-development", "artifacts", "net")
  )
}

export async function readNetLock(root = repoRoot) {
  return JSON.parse(await readFile(join(root, "scripts", "net-build.lock.json"), "utf8"))
}

/// Hash of everything that affects the native build: the lock, the cargo
/// manifests/lockfile, and every Rust source file. Sorted for stability.
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
  for (const file of files.toSorted()) {
    hash.update(relative(root, file))
    hash.update("\0")
    hash.update(await readFile(file))
    hash.update("\0")
  }
  return hash.digest("hex").slice(0, 16)
}

const exists = (path) =>
  access(path).then(
    () => true,
    () => false
  )

function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: "inherit", ...options })
    child.on("error", reject)
    child.on("exit", (code) =>
      code === 0 ? resolve() : reject(new Error(`${command} ${args.join(" ")} exited ${code}`))
    )
  })
}

/// Where rustup's `cargo`/`rustc` proxies live: rustup's own installer puts them in
/// ~/.cargo/bin, Homebrew's (keg-only) `rustup` formula in its opt prefix. Anything else on PATH
/// named cargo may be a standalone toolchain (Homebrew's `rust`) that has none of the targets
/// rustup installs and, on macOS 27, builds proc-macros the loader rejects.
export const rustupProxyDirectories = (home = homedir()) => [
  join(home, ".cargo", "bin"),
  "/opt/homebrew/opt/rustup/bin",
  "/usr/local/opt/rustup/bin"
]

/// The first directory holding both rustup and its cargo proxy, else undefined.
export async function findRustup(directories = rustupProxyDirectories()) {
  for (const directory of directories) {
    if ((await exists(join(directory, "rustup"))) && (await exists(join(directory, "cargo")))) {
      return directory
    }
  }
  return undefined
}

/// The environment every cargo invocation runs in: rustup's proxies first on PATH and the
/// toolchain pinned in net-build.lock.json selected, so the build never depends on which cargo
/// happens to be first on PATH or on rustup's default. Installs the pinned toolchain if missing.
export async function cargoEnv(environment = process.env, directories = rustupProxyDirectories()) {
  const directory = await findRustup(directories)
  if (directory === undefined) {
    throw new Error(
      "The tunnel's native code builds with rustup. Install it (brew install rustup, or " +
        "https://rustup.rs); the Rust version is pinned in scripts/net-build.lock.json."
    )
  }
  const { rust } = await readNetLock()
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

/// Builds (or reuses) the Node addon for this host and installs it into
/// packages/net/native/<target>/. Returns the installed path.
export async function ensureNodeAddon(environment = process.env) {
  const stamp = await netSourceStamp()
  const target = hostTarget()
  const cached = join(netArtifactsRoot(environment), stamp, "node", target, "codevisor_net.node")
  const installed = join(netRoot, "native", target, "codevisor_net.node")
  if (!(await exists(cached))) {
    await withArtifactLock(`${cached}.lock`, async () => {
      if (await exists(cached)) return
      console.log(`Building the codevisor-net Node addon (${stamp}, ${target})`)
      let library
      if (process.platform === "linux") {
        // Linked against an old glibc so the addon loads wherever the bundled Node runs: built
        // natively on Ubuntu 24.04 it needed glibc 2.33+ and failed on Ubuntu 20.04 and Debian
        // 11, leaving those servers without the tunnel (tunnel-only apps can't reach them).
        const lock = await readNetLock()
        const triple = `${process.arch === "arm64" ? "aarch64" : "x86_64"}-unknown-linux-gnu`
        const args = ["--release", "--locked", "-p", "codevisor-net-node"]
        await run("cargo", ["zigbuild", ...args, "--target", `${triple}.${lock.linuxGlibc}`], {
          cwd: netRoot,
          env: await cargoEnv(environment)
        })
        library = join(netRoot, "target", triple, "release", "libcodevisor_net_node.so")
      } else {
        await run("cargo", ["build", "--release", "--locked", "-p", "codevisor-net-node"], {
          cwd: netRoot,
          env: await cargoEnv(environment)
        })
        library = join(netRoot, "target", "release", "libcodevisor_net_node.dylib")
      }
      await mkdir(dirname(cached), { recursive: true })
      await copyFile(library, `${cached}.tmp`)
      await rename(`${cached}.tmp`, cached)
    })
  }
  const stampFile = join(dirname(installed), "STAMP")
  if ((await readFile(stampFile, "utf8").catch(() => "")) !== stamp || !(await exists(installed))) {
    await mkdir(dirname(installed), { recursive: true })
    await copyFile(cached, `${installed}.tmp`)
    await rename(`${installed}.tmp`, installed)
    await writeFile(stampFile, stamp)
  }
  return installed
}

/// Builds (or reuses) the Linux Node addon for the dev containers, inside a
/// pinned Rust container on the same engine (no cross toolchain on the host),
/// and installs it into packages/net/native/linux-<arch>/.
export async function ensureLinuxNodeAddon(engine, arch = process.arch, environment = process.env) {
  const stamp = await netSourceStamp()
  const lock = await readNetLock()
  const target = `linux-${arch}`
  const cached = join(netArtifactsRoot(environment), stamp, "node", target, "codevisor_net.node")
  const installed = join(netRoot, "native", target, "codevisor_net.node")
  if (!(await exists(cached))) {
    await withArtifactLock(`${cached}.lock`, async () => {
      if (await exists(cached)) return
      console.log(`Building the codevisor-net Linux addon in a container (${stamp}, ${target})`)
      const cargoHome = join(netArtifactsRoot(environment), "linux-cargo-home")
      await mkdir(cargoHome, { recursive: true })
      await run(engine === "apple" ? "container" : "docker", [
        "run",
        "--rm",
        "--cpus",
        "4",
        "--memory",
        "6g",
        "--volume",
        `${netRoot}:/src`,
        "--volume",
        `${cargoHome}:/cargo-home`,
        "--env",
        "CARGO_HOME=/cargo-home",
        "--workdir",
        "/src",
        `rust:${lock.rust}-bookworm`,
        "cargo",
        "build",
        "--release",
        "--locked",
        "-p",
        "codevisor-net-node",
        "--target-dir",
        "/src/target/linux"
      ])
      await mkdir(dirname(cached), { recursive: true })
      await copyFile(
        join(netRoot, "target", "linux", "release", "libcodevisor_net_node.so"),
        `${cached}.tmp`
      )
      await rename(`${cached}.tmp`, cached)
    })
  }
  await mkdir(dirname(installed), { recursive: true })
  await copyFile(cached, installed)
  return installed
}

/// Downloads (or reuses) the pinned iroh-relay binary for this host.
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
    // The archive stores `./iroh-relay`; GNU tar matches member names
    // literally (bsdtar on macOS accepts either spelling).
    await run("tar", ["-xzf", "relay.tar.gz", "./iroh-relay"], { cwd: staging })
    await mkdir(dirname(binary), { recursive: true })
    await rename(join(staging, "iroh-relay"), binary)
    await rm(staging, { recursive: true, force: true })
  })
  return binary
}

/// Builds (or reuses) CodevisorNetFFI.xcframework in the shared cache, links
/// it into packages/swift/Frameworks/ for SwiftPM's local binaryTarget, and
/// refreshes the committed uniffi Swift bindings (CI fails if they drift).
export async function ensureSwiftFramework(environment = process.env) {
  const stamp = await netSourceStamp()
  const cached = join(netArtifactsRoot(environment), stamp, "apple")
  const framework = join(cached, "CodevisorNetFFI.xcframework")
  if (!(await exists(join(framework, "Info.plist")))) {
    await withArtifactLock(`${cached}.lock`, async () => {
      if (await exists(join(framework, "Info.plist"))) return
      console.log(`Building CodevisorNetFFI.xcframework (${stamp})`)
      await rm(`${cached}.staging`, { recursive: true, force: true })
      await run("bash", [join(repoRoot, "scripts", "build-net-swift.sh"), `${cached}.staging`], {
        cwd: netRoot,
        env: await cargoEnv(environment)
      })
      await rm(cached, { recursive: true, force: true })
      await rename(`${cached}.staging`, cached)
    })
  }
  const link = join(repoRoot, "packages", "swift", "Frameworks", "CodevisorNetFFI.xcframework")
  await mkdir(dirname(link), { recursive: true })
  if ((await readlink(link).catch(() => undefined)) !== framework) {
    await rm(link, { recursive: true, force: true })
    await symlink(framework, link)
  }
  const bindings = join(
    repoRoot,
    "packages/swift/CodevisorNet/Sources/CodevisorNet/Generated/codevisor_net_ffi.swift"
  )
  const generated = await readFile(join(cached, "codevisor_net_ffi.swift"), "utf8")
  if ((await readFile(bindings, "utf8").catch(() => "")) !== generated) {
    await mkdir(dirname(bindings), { recursive: true })
    await writeFile(bindings, generated)
  }
  return link
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
      // `net-artifact.mjs cargo ARGS…`: cargo with the pinned toolchain, for scripts like net:test.
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
