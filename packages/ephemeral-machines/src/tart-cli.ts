import { spawn } from "node:child_process"
import { mkdir, statfs } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"
import { setTimeout as delay } from "node:timers/promises"

import type { ExecResult } from "./provider.js"
import type { TartHost, TartRunOptions } from "./tart.js"

const outputLimitChars = 256_000

export const tartCliHost = (binary = "tart"): TartHost => {
  const { TMPDIR: _ownTemporaryDirectory, ...inherited } = process.env
  const environment = { ...inherited, TART_NO_AUTO_PRUNE: "1" }
  return {
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
    freeDiskBytes: async () => {
      const home = process.env.TART_HOME ?? join(homedir(), ".tart")
      await mkdir(home, { recursive: true })
      const stats = await statfs(home)
      return stats.bavail * stats.bsize
    },
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
      stdout = (stdout + chunk.toString("utf8")).slice(-outputLimitChars)
    })
    child.stderr.on("data", (chunk: Buffer) => {
      stderr = (stderr + chunk.toString("utf8")).slice(-outputLimitChars)
    })
    child.on("error", (cause) => resolve({ exitCode: 127, stdout, stderr: cause.message }))
    child.on("close", (code) => resolve({ exitCode: code ?? 1, stdout, stderr }))
    child.stdin.on("error", () => undefined)
    child.stdin.end(options.stdin ?? "")
  })
