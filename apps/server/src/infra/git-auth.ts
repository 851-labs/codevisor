import { spawn, type ChildProcess } from "node:child_process"
import { randomUUID } from "node:crypto"

import { gitHostProvider, type GitAuthFlow, type GitHostAuthStatus } from "@codevisor/api"

type CliProvider = "github" | "gitlab"

interface ProviderCli {
  readonly command: string
  readonly status: (host: string) => ReadonlyArray<string>
  readonly login: (host: string) => ReadonlyArray<string>
  readonly setupGit?: (host: string) => ReadonlyArray<string>
}

const providerClis: Record<CliProvider, ProviderCli> = {
  github: {
    command: "gh",
    status: (host) => ["auth", "status", "--hostname", host],
    login: (host) => [
      "auth",
      "login",
      "--web",
      "--hostname",
      host,
      "--git-protocol",
      "https",
      "--skip-ssh-key"
    ],
    setupGit: (host) => ["auth", "setup-git", "--hostname", host]
  },
  gitlab: {
    command: "glab",
    status: (host) => ["auth", "status", "--hostname", host],
    login: (host) => [
      "auth",
      "login",
      "--hostname",
      host,
      "--device",
      "--git-protocol",
      "https",
      "--setup-git-credential-helper"
    ]
  }
}

export interface GitAuthTimings {
  readonly codeWaitMs: number
  readonly loginTimeoutMs: number
  readonly retentionMs: number
}

const defaultTimings: GitAuthTimings = {
  codeWaitMs: 10_000,
  loginTimeoutMs: 15 * 60_000,
  retentionMs: 10 * 60_000
}

interface CommandResult {
  readonly code: number | null
  readonly output: string
  readonly missing: boolean
}

const cliEnvironment = (env: NodeJS.ProcessEnv): NodeJS.ProcessEnv => ({
  ...env,
  BROWSER: "true",
  GH_BROWSER: "true",
  GLAB_BROWSER: "true",
  NO_COLOR: "1",
  GH_NO_UPDATE_NOTIFIER: "1",
  GLAB_CHECK_UPDATE: "false"
})

const runCommand = (
  command: string,
  args: ReadonlyArray<string>,
  env: NodeJS.ProcessEnv
): Promise<CommandResult> =>
  new Promise((resolve) => {
    const child = spawn(command, [...args], {
      env: cliEnvironment(env),
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 20_000
    })
    let output = ""
    child.stdout.setEncoding("utf8")
    child.stderr.setEncoding("utf8")
    child.stdout.on("data", (chunk: string) => (output += chunk))
    child.stderr.on("data", (chunk: string) => (output += chunk))
    child.once("error", (cause: NodeJS.ErrnoException) => {
      resolve({ code: null, output: cause.message, missing: cause.code === "ENOENT" })
    })
    child.once("close", (code) => {
      resolve({ code, output, missing: false })
    })
  })

const accountPattern = /(?:account|as)\s+([A-Za-z0-9][\w.-]*)/

export const parseDeviceCode = (text: string): string | undefined =>
  (/code:?\s+([A-Z0-9]{4,}(?:-[A-Z0-9]{4,})+)/i.exec(text) ??
    /\b([A-Z0-9]{4}-[A-Z0-9]{4})\b/.exec(text))?.[1]

export const parseVerificationUrl = (text: string): string | undefined =>
  /(https?:\/\/[^\s"'<>]+)/.exec(text)?.[1]?.replace(/[.,;:)]+$/, "")

const cliProvider = (host: string): CliProvider | undefined => {
  const provider = gitHostProvider(host)
  return provider === "github" || provider === "gitlab" ? provider : undefined
}

interface LoginFlow {
  flow: GitAuthFlow
  readonly child: ChildProcess
  done: boolean
}

export interface GitAuthManager {
  readonly status: (host: string) => Promise<GitHostAuthStatus>
  readonly begin: (host: string) => Promise<GitAuthFlow>
  readonly flow: (flowId: string) => GitAuthFlow | undefined
  readonly cancel: (flowId: string) => boolean
}

export const makeGitAuthManager = (
  resolveEnvironment: () => Promise<NodeJS.ProcessEnv>,
  timings: GitAuthTimings = defaultTimings
): GitAuthManager => {
  const flows = new Map<string, LoginFlow>()

  const status = async (rawHost: string): Promise<GitHostAuthStatus> => {
    const host = rawHost.trim().toLowerCase()
    const provider = gitHostProvider(host)
    const cliId = cliProvider(host)
    if (cliId === undefined) {
      return {
        host,
        ...(provider === undefined ? {} : { provider }),
        cliInstalled: false,
        supported: false,
        signedIn: false
      }
    }
    const cli = providerClis[cliId]
    const result = await runCommand(cli.command, cli.status(host), await resolveEnvironment())
    const account = result.code === 0 ? accountPattern.exec(result.output)?.[1] : undefined
    return {
      host,
      provider: cliId,
      cli: cli.command,
      cliInstalled: !result.missing,
      supported: true,
      signedIn: result.code === 0,
      ...(account === undefined ? {} : { account })
    }
  }

  const finish = (entry: LoginFlow, update: Partial<GitAuthFlow>): void => {
    if (entry.done) return
    entry.done = true
    entry.flow = { ...entry.flow, ...update }
    entry.child.kill("SIGTERM")
    setTimeout(() => flows.delete(entry.flow.id), timings.retentionMs).unref()
  }

  const begin = async (rawHost: string): Promise<GitAuthFlow> => {
    const host = rawHost.trim().toLowerCase()
    const provider = cliProvider(host)
    if (provider === undefined) {
      throw new Error(`Signing in to ${host} isn't supported yet`)
    }
    for (const entry of flows.values()) {
      if (entry.flow.host === host) finish(entry, { state: "cancelled" })
    }
    const cli = providerClis[provider]
    const env = await resolveEnvironment()
    const id = randomUUID()
    const child = spawn(cli.command, [...cli.login(host)], {
      env: cliEnvironment(env),
      stdio: ["ignore", "pipe", "pipe"]
    })
    const entry: LoginFlow = {
      flow: { id, host, provider, state: "starting" },
      child,
      done: false
    }
    flows.set(id, entry)
    let output = ""
    const accept = (chunk: string): void => {
      output += chunk
      if (entry.flow.state !== "starting") return
      const userCode = parseDeviceCode(output)
      const verificationUrl = parseVerificationUrl(output)
      if (userCode === undefined || verificationUrl === undefined) return
      entry.flow = { ...entry.flow, state: "waiting", userCode, verificationUrl }
    }
    child.stdout.setEncoding("utf8")
    child.stderr.setEncoding("utf8")
    child.stdout.on("data", accept)
    child.stderr.on("data", accept)
    const timer = setTimeout(() => {
      finish(entry, { state: "error", message: "Sign-in timed out. Try again." })
    }, timings.loginTimeoutMs)
    timer.unref()
    child.once("error", (cause: NodeJS.ErrnoException) => {
      clearTimeout(timer)
      finish(entry, {
        state: "error",
        message:
          cause.code === "ENOENT" ? `${cli.command} isn't installed on this machine` : cause.message
      })
    })
    child.once("close", (code) => {
      clearTimeout(timer)
      if (entry.done) return
      if (code !== 0) {
        const tail = output.trim().split("\n").slice(-3).join("\n")
        finish(entry, {
          state: "error",
          message: `${cli.command} sign-in failed (exit ${String(code)}).\n${tail}`.trim()
        })
        return
      }
      void (async () => {
        if (cli.setupGit !== undefined) await runCommand(cli.command, cli.setupGit(host), env)
        const signedIn = await status(host)
        finish(entry, {
          state: "complete",
          ...(signedIn.account === undefined ? {} : { account: signedIn.account })
        })
      })()
    })
    const deadline = Date.now() + timings.codeWaitMs
    while (entry.flow.state === "starting" && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 100))
    }
    return entry.flow
  }

  return {
    status,
    begin,
    flow: (flowId) => flows.get(flowId)?.flow,
    cancel: (flowId) => {
      const entry = flows.get(flowId)
      if (entry === undefined) return false
      finish(entry, { state: "cancelled" })
      return true
    }
  }
}
