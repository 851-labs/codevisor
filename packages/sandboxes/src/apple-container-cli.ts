import { execFile, spawn } from "node:child_process"
import { mkdtemp, rm, statfs, writeFile } from "node:fs/promises"
import { cpus, homedir, tmpdir, totalmem } from "node:os"
import { delimiter, join } from "node:path"
import { setTimeout as delay } from "node:timers/promises"
import { promisify } from "node:util"

import type { ContainerHost, ContainerRunOptions } from "./apple-container-host.js"
import {
  containerToolchain,
  parseContainerVersion,
  type ContainerInstallDeps,
  type ContainerToolchain
} from "./apple-container-install.js"
import type { ExecResult } from "./provider.js"

const execFileAsync = promisify(execFile)
const outputLimitChars = 256_000
const downloadTimeoutMs = 10 * 60_000
const versionTimeoutMs = 10_000
const wellKnownDirectories = ["/usr/local/bin", "/opt/homebrew/bin"]

export const downloadContainer = async (url: string): Promise<Buffer> => {
  const response = await fetch(url, { signal: AbortSignal.timeout(downloadTimeoutMs) })
  if (!response.ok) throw new Error(`HTTP ${String(response.status)}`)
  return Buffer.from(await response.arrayBuffer())
}

export const systemContainerCandidates = (
  override: string | undefined,
  path: string | undefined = process.env.PATH
): ReadonlyArray<string> => {
  if (override !== undefined) return [override]

  const directories = [...(path ?? "").split(delimiter).filter(Boolean), ...wellKnownDirectories]
  return [...new Set(directories.map((directory) => join(directory, "container")))]
}

export const managedContainerToolchain = (
  toolsDir: string,
  candidates: ReadonlyArray<string>
): ContainerToolchain => containerToolchain(toolsDir, cliInstallDeps(candidates))

export const containerCliHost = (toolchain: ContainerToolchain): ContainerHost => ({
  locate: toolchain.locate,
  install: toolchain.install,
  run: async (args, options) => {
    const cli = await toolchain.locate()
    if (cli === undefined) return { exitCode: 127, stdout: "", stderr: "container isn't installed" }
    return runContainer(cli.binary, args, options)
  },
  macOSVersion: async () =>
    (await execFileAsync("/usr/bin/sw_vers", ["-productVersion"])).stdout.trim(),
  freeDiskBytes: async () => {
    const stats = await statfs(homedir())
    return stats.bavail * stats.bsize
  },
  hardware: () => ({ cpus: cpus().length, memoryBytes: totalmem() }),
  buildContext: async (containerfile) => {
    const directory = await mkdtemp(join(tmpdir(), "codevisor-container-build-"))
    const file = join(directory, "Containerfile")
    await writeFile(file, containerfile)
    return { file, directory, dispose: () => rm(directory, { recursive: true, force: true }) }
  },
  sleep: (ms) => delay(ms)
})

const cliInstallDeps = (candidates: ReadonlyArray<string>): ContainerInstallDeps => ({
  candidates,
  version: async (binary) => {
    try {
      const { stdout } = await execFileAsync(binary, ["--version"], { timeout: versionTimeoutMs })
      return parseContainerVersion(stdout)
    } catch {
      return undefined
    }
  },
  download: downloadContainer,
  expand: async (pkg, target) => {
    await execFileAsync("/usr/sbin/pkgutil", ["--expand-full", pkg, target])
  }
})

const runContainer = (
  binary: string,
  args: ReadonlyArray<string>,
  options: ContainerRunOptions = {}
): Promise<ExecResult> =>
  new Promise((resolve) => {
    const child = spawn(binary, [...args], {
      stdio: ["pipe", "pipe", "pipe"],
      ...(options.timeoutMs === undefined ? {} : { timeout: options.timeoutMs })
    })
    let stdout = ""
    let stderr = ""
    child.stdout.on("data", (chunk: Buffer) => {
      const text = chunk.toString("utf8")
      stdout = (stdout + text).slice(-outputLimitChars)
      options.onOutput?.("stdout", text)
    })
    child.stderr.on("data", (chunk: Buffer) => {
      const text = chunk.toString("utf8")
      stderr = (stderr + text).slice(-outputLimitChars)
      options.onOutput?.("stderr", text)
    })
    child.on("error", (cause) => resolve({ exitCode: 127, stdout, stderr: cause.message }))
    child.on("close", (code) => resolve({ exitCode: code ?? 1, stdout, stderr }))
    child.stdin.on("error", () => undefined)
    child.stdin.end(options.stdin ?? "")
  })
