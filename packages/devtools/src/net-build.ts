import { copyFile, mkdir, rename, rm } from "node:fs/promises"
import { dirname, join } from "node:path"

import { runCommand } from "./commands.ts"
import {
  cargoEnvironment,
  hostTarget,
  netArtifactsRoot,
  netNativeRoot,
  netRoot,
  readNetLock,
  rustToolchain
} from "./net-artifact.ts"

type Environment = Readonly<Record<string, string | undefined>>

export async function buildNodeAddon(
  repoRoot: string,
  target: string,
  environment: Environment = process.env
): Promise<void> {
  const library = await compileNodeAddon(repoRoot, target, environment)
  await installAtomically(library, join(netNativeRoot(repoRoot), target, "codevisor_net.node"))
}

export async function buildSwiftFramework(
  repoRoot: string,
  environment: Environment = process.env
): Promise<void> {
  const destination = join(netNativeRoot(repoRoot), "apple")
  const staging = `${destination}.staging`
  await rm(staging, { recursive: true, force: true })
  await runCommand("bash", [join(repoRoot, "scripts", "build-net-swift.sh"), staging], {
    cwd: netRoot(repoRoot),
    env: await cargoEnvironment(repoRoot, environment)
  })
  await rm(destination, { recursive: true, force: true })
  await rename(staging, destination)
}

export function linuxContainerBuild(options: {
  readonly target: string
  readonly netRoot: string
  readonly cargoHome: string
  readonly rust: string
}): Array<string> {
  return [
    "run",
    "--rm",
    "--cpus",
    "4",
    "--memory",
    "6g",
    "--volume",
    `${options.netRoot}:/src`,
    "--volume",
    `${options.cargoHome}:/cargo-home`,
    "--env",
    "CARGO_HOME=/cargo-home",
    "--workdir",
    "/src",
    `rust:${options.rust}-bookworm`,
    "cargo",
    "build",
    "--release",
    "--locked",
    "-p",
    "codevisor-net-node",
    "--target-dir",
    `/src/target/${options.target}`
  ]
}

async function compileNodeAddon(
  repoRoot: string,
  target: string,
  environment: Environment
): Promise<string> {
  if (target === hostTarget()) return compileForHost(repoRoot, environment)
  if (target.startsWith("linux-")) return compileInLinuxContainer(repoRoot, target, environment)

  throw new Error(`can't build the codevisor-net addon for ${target} on ${hostTarget()}`)
}

async function compileForHost(repoRoot: string, environment: Environment): Promise<string> {
  const args = ["--release", "--locked", "-p", "codevisor-net-node"]
  const env = await cargoEnvironment(repoRoot, environment)
  const cwd = netRoot(repoRoot)
  if (process.platform !== "linux") {
    await runCommand("cargo", ["build", ...args], { cwd, env })
    return join(cwd, "target", "release", "libcodevisor_net_node.dylib")
  }

  const lock = await readNetLock(repoRoot)
  const triple = `${process.arch === "arm64" ? "aarch64" : "x86_64"}-unknown-linux-gnu`
  await runCommand("cargo", ["zigbuild", ...args, "--target", `${triple}.${lock.linuxGlibc}`], {
    cwd,
    env
  })
  return join(cwd, "target", triple, "release", "libcodevisor_net_node.so")
}

async function compileInLinuxContainer(
  repoRoot: string,
  target: string,
  environment: Environment
): Promise<string> {
  const cargoHome = join(netArtifactsRoot(environment), "linux-cargo-home")
  await mkdir(cargoHome, { recursive: true })
  const engine = environment.CODEVISOR_CONTAINER_ENGINE === "apple" ? "container" : "docker"
  await runCommand(
    engine,
    linuxContainerBuild({
      target,
      netRoot: netRoot(repoRoot),
      cargoHome,
      rust: await rustToolchain(repoRoot)
    })
  )
  return join(netRoot(repoRoot), "target", target, "release", "libcodevisor_net_node.so")
}

async function installAtomically(source: string, destination: string): Promise<void> {
  await mkdir(dirname(destination), { recursive: true })
  await copyFile(source, `${destination}.tmp`)
  await rename(`${destination}.tmp`, destination)
}
