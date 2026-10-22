import { spawn } from "node:child_process"

import { parseDevicePrompt } from "./device-code.js"
import type { DeviceCode, GitHostLogin, GitHostLoginResult } from "./git-host.js"

export interface DeviceLoginCommand {
  readonly command: string
  readonly path: string | undefined
  readonly args: ReadonlyArray<string>
  readonly env: NodeJS.ProcessEnv
}

const failureTailLines = 3

export const startDeviceLogin = (
  login: DeviceLoginCommand,
  onDeviceCode: (code: DeviceCode) => void
): GitHostLogin => {
  if (login.path === undefined) {
    return { finished: Promise.resolve(notInstalled(login.command)), cancel: () => undefined }
  }

  const child = spawn(login.path, [...login.args], {
    env: login.env,
    stdio: ["ignore", "pipe", "pipe"]
  })
  const finished = new Promise<GitHostLoginResult>((resolve) => {
    const prompt = devicePromptReader(onDeviceCode)
    child.stdout.setEncoding("utf8")
    child.stderr.setEncoding("utf8")
    child.stdout.on("data", prompt.accept)
    child.stderr.on("data", prompt.accept)
    child.once("error", (cause: NodeJS.ErrnoException) => {
      resolve(spawnFailure(login.command, cause))
    })
    child.once("close", (code) => resolve(exitResult(login.command, code, prompt.output())))
  })
  return { finished, cancel: () => child.kill("SIGTERM") }
}

const devicePromptReader = (onDeviceCode: (code: DeviceCode) => void) => {
  let output = ""
  let announced = false
  return {
    output: () => output,
    accept: (chunk: string): void => {
      output += chunk
      if (announced) return

      const code = parseDevicePrompt(output)
      if (code === undefined) return

      announced = true
      onDeviceCode(code)
    }
  }
}

const notInstalled = (command: string): GitHostLoginResult => ({
  signedIn: false,
  message: `${command} isn't installed on this machine`
})

const spawnFailure = (command: string, cause: NodeJS.ErrnoException): GitHostLoginResult => {
  if (cause.code === "ENOENT") return notInstalled(command)
  return { signedIn: false, message: cause.message }
}

const exitResult = (command: string, code: number | null, output: string): GitHostLoginResult => {
  if (code === 0) return { signedIn: true }

  const tail = output.trim().split("\n").slice(-failureTailLines).join("\n")
  return {
    signedIn: false,
    message: `${command} sign-in failed (exit ${String(code)}).\n${tail}`.trim()
  }
}
