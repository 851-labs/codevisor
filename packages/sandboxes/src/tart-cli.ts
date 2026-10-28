import { spawn } from "node:child_process"
import { mkdir, statfs } from "node:fs/promises"
import { cpus, homedir, totalmem } from "node:os"
import { basename, dirname, join } from "node:path"
import { setTimeout as delay } from "node:timers/promises"

import { imageDiskBytes, type ManifestFetch } from "./oci-manifest.js"
import type { ExecResult } from "./provider.js"
import type { TartDownload, TartInstall } from "./tart-install.js"
import type { TartHost, TartRunOptions } from "./tart.js"

const outputLimitChars = 256_000
const downloadTimeoutMs = 10 * 60_000
const manifestTimeoutMs = 15_000

export const downloadTart: TartDownload = async (url) => {
  const response = await fetch(url, { signal: AbortSignal.timeout(downloadTimeoutMs) })
  if (!response.ok) throw new Error(`HTTP ${String(response.status)}`)
  return Buffer.from(await response.arrayBuffer())
}

export const tartCliHost = (tart: TartInstall): TartHost => {
  const { TMPDIR: _ownTemporaryDirectory, ...inherited } = process.env
  const environment = { ...inherited, TART_NO_AUTO_PRUNE: "1" }
  const binary = tart.binary
  return {
    installed: tart.installed,
    install: tart.install,
    run: (args, options) => runTart(binary, args, environment, options),
    start: (args) => {
      const child = spawn(
        "/bin/sh",
        ["-c", 'nohup "$@" >/dev/null 2>&1 &', "sh", binary, ...args],
        {
          env: environment,
          detached: true,
          stdio: "ignore"
        }
      )
      child.on("error", () => undefined)
      child.unref()
    },
    copyIn: (vm, source, destination) =>
      copyIntoVm(binary, environment, { vm, source, destination }),
    freeDiskBytes: async () => {
      const home = process.env.TART_HOME ?? join(homedir(), ".tart")
      await mkdir(home, { recursive: true })
      const stats = await statfs(home)
      return stats.bavail * stats.bsize
    },
    hardware: () => ({ cpus: cpus().length, memoryBytes: totalmem() }),
    imageBytes: (image) => imageDiskBytes(image, fetchManifest),
    sleep: (ms) => delay(ms)
  }
}

const runTart = (
  binary: string,
  args: ReadonlyArray<string>,
  environment: NodeJS.ProcessEnv,
  options: TartRunOptions = {}
): Promise<ExecResult> =>
  new Promise((resolve) => {
    const child = spawn(binary, [...args], {
      env: environment,
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

interface CopyRequest {
  readonly vm: string
  readonly source: string
  readonly destination: string
}

const guestUnpack = 'sudo rm -rf "$1/$2" && sudo tar -C "$1" -xf -'

const copyIntoVm = (
  binary: string,
  environment: NodeJS.ProcessEnv,
  request: CopyRequest
): Promise<ExecResult> =>
  new Promise((resolve) => {
    const name = basename(request.source)
    const archive = spawn("tar", ["-C", dirname(request.source), "-cf", "-", name], {
      env: { ...environment, COPYFILE_DISABLE: "1" },
      stdio: ["ignore", "pipe", "pipe"]
    })
    const unpack = spawn(
      binary,
      ["exec", "-i", request.vm, "sh", "-c", guestUnpack, "sh", request.destination, name],
      { env: environment, stdio: ["pipe", "pipe", "pipe"] }
    )
    let stderr = ""
    const collect = (chunk: Buffer) => {
      stderr = (stderr + chunk.toString("utf8")).slice(-outputLimitChars)
    }
    archive.stderr.on("data", collect)
    unpack.stderr.on("data", collect)
    unpack.stdout.resume()
    unpack.stdin.on("error", () => undefined)
    archive.stdout.pipe(unpack.stdin)
    archive.on("error", (cause) => resolve({ exitCode: 127, stdout: "", stderr: cause.message }))
    unpack.on("error", (cause) => resolve({ exitCode: 127, stdout: "", stderr: cause.message }))
    unpack.on("close", (code) => resolve({ exitCode: code ?? 1, stdout: "", stderr }))
  })

const fetchManifest: ManifestFetch = (url, headers) =>
  fetch(url, { headers, signal: AbortSignal.timeout(manifestTimeoutMs) })
