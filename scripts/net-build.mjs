#!/usr/bin/env node
import { copyFile, mkdir, rename, rm } from "node:fs/promises"
import { dirname, join } from "node:path"
import process from "node:process"
import { fileURLToPath } from "node:url"

import {
  cargoEnv,
  hostTarget,
  netArtifactsRoot,
  netNativeRoot,
  netRoot,
  readNetLock,
  repoRoot,
  run
} from "./net-artifact.mjs"

export async function buildNodeAddon(target, environment = process.env) {
  const library = await compileNodeAddon(target, environment)
  await installAtomically(library, join(netNativeRoot, target, "codevisor_net.node"))
}

export async function buildSwiftFramework(environment = process.env) {
  const destination = join(netNativeRoot, "apple")
  const staging = `${destination}.staging`
  await rm(staging, { recursive: true, force: true })
  await run("bash", [join(repoRoot, "scripts", "build-net-swift.sh"), staging], {
    cwd: netRoot,
    env: await cargoEnv(environment)
  })
  await rm(destination, { recursive: true, force: true })
  await rename(staging, destination)
}

function compileNodeAddon(target, environment) {
  if (target === hostTarget()) return compileForHost(environment)
  if (target.startsWith("linux-")) return compileInLinuxContainer(target, environment)

  throw new Error(`can't build the codevisor-net addon for ${target} on ${hostTarget()}`)
}

async function compileForHost(environment) {
  const args = ["--release", "--locked", "-p", "codevisor-net-node"]
  const env = await cargoEnv(environment)
  if (process.platform !== "linux") {
    await run("cargo", ["build", ...args], { cwd: netRoot, env })
    return join(netRoot, "target", "release", "libcodevisor_net_node.dylib")
  }

  const lock = await readNetLock()
  const triple = `${process.arch === "arm64" ? "aarch64" : "x86_64"}-unknown-linux-gnu`
  await run("cargo", ["zigbuild", ...args, "--target", `${triple}.${lock.linuxGlibc}`], {
    cwd: netRoot,
    env
  })
  return join(netRoot, "target", triple, "release", "libcodevisor_net_node.so")
}

async function compileInLinuxContainer(target, environment) {
  const lock = await readNetLock()
  const cargoHome = join(netArtifactsRoot(environment), "linux-cargo-home")
  await mkdir(cargoHome, { recursive: true })
  const engine = environment.CODEVISOR_CONTAINER_ENGINE === "apple" ? "container" : "docker"
  await run(engine, linuxContainerBuild(target, cargoHome, lock.rust))
  return join(netRoot, "target", target, "release", "libcodevisor_net_node.so")
}

function linuxContainerBuild(target, cargoHome, rust) {
  return [
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
    `rust:${rust}-bookworm`,
    "cargo",
    "build",
    "--release",
    "--locked",
    "-p",
    "codevisor-net-node",
    "--target-dir",
    `/src/target/${target}`
  ]
}

async function installAtomically(source, destination) {
  await mkdir(dirname(destination), { recursive: true })
  await copyFile(source, `${destination}.tmp`)
  await rename(`${destination}.tmp`, destination)
}

async function main([kind, target]) {
  if (kind === "swift") return buildSwiftFramework()
  if (kind === "node" && target !== undefined) return buildNodeAddon(target)

  throw new Error("usage: net-build.mjs <swift | node <target>>")
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(error.message)
    process.exitCode = 1
  })
}
