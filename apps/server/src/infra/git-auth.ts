import { randomUUID } from "node:crypto"

import { gitHostProvider, type GitAuthFlow, type GitHostAuthStatus } from "@codevisor/api"
import type { DeviceCode, GitHost, GitHostLogin, GitHosts } from "@codevisor/git-hosts"

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

interface LoginFlow {
  flow: GitAuthFlow
  readonly login: GitHostLogin
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
  hosts: GitHosts,
  timings: GitAuthTimings = defaultTimings
): GitAuthManager => {
  const flows = new Map<string, LoginFlow>()

  const status = async (rawHost: string): Promise<GitHostAuthStatus> => {
    const host = normalizedHost(rawHost)
    const gitHost = hosts.forHost(host)
    if (gitHost === undefined) return unsupportedStatus(host)

    const signIn = await gitHost.authStatus(host, await resolveEnvironment())
    return {
      host,
      provider: gitHost.provider,
      cli: gitHost.command,
      supported: true,
      ...signIn
    }
  }

  const finish = (entry: LoginFlow, update: Partial<GitAuthFlow>): void => {
    if (entry.done) return
    entry.done = true
    entry.flow = { ...entry.flow, ...update }
    entry.login.cancel()
    setTimeout(() => flows.delete(entry.flow.id), timings.retentionMs).unref()
  }

  const cancelSignInsFor = (host: string): void => {
    for (const entry of flows.values()) {
      if (entry.flow.host === host) finish(entry, { state: "cancelled" })
    }
  }

  const complete = async (
    entry: LoginFlow,
    gitHost: GitHost,
    env: NodeJS.ProcessEnv
  ): Promise<void> => {
    await gitHost.setUpGitCredentials?.(entry.flow.host, env)
    const signedIn = await status(entry.flow.host)
    finish(entry, {
      state: "complete",
      ...(signedIn.account === undefined ? {} : { account: signedIn.account })
    })
  }

  const begin = async (rawHost: string): Promise<GitAuthFlow> => {
    const host = normalizedHost(rawHost)
    const gitHost = hosts.forHost(host)
    if (gitHost === undefined) throw new Error(`Signing in to ${host} isn't supported yet`)

    cancelSignInsFor(host)
    const env = await resolveEnvironment()
    const entry = startLogin(gitHost, host, env)
    flows.set(entry.flow.id, entry)
    const timer = setTimeout(() => {
      finish(entry, { state: "error", message: "Sign-in timed out. Try again." })
    }, timings.loginTimeoutMs)
    timer.unref()
    void entry.login.finished.then((result) => {
      clearTimeout(timer)
      if (entry.done) return
      if (!result.signedIn) return finish(entry, { state: "error", message: result.message })
      return complete(entry, gitHost, env)
    })
    await waitForCode(entry, timings.codeWaitMs)
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

const normalizedHost = (host: string): string => host.trim().toLowerCase()

const unsupportedStatus = (host: string): GitHostAuthStatus => {
  const provider = gitHostProvider(host)
  return {
    host,
    ...(provider === undefined ? {} : { provider }),
    cliInstalled: false,
    supported: false,
    signedIn: false
  }
}

const startLogin = (gitHost: GitHost, host: string, env: NodeJS.ProcessEnv): LoginFlow => {
  const flow: GitAuthFlow = {
    id: randomUUID(),
    host,
    provider: gitHost.provider,
    state: "starting"
  }
  const showCode = (code: DeviceCode): void => {
    if (entry.flow.state !== "starting") return
    entry.flow = { ...entry.flow, state: "waiting", ...code }
  }
  const entry: LoginFlow = { flow, login: gitHost.login(host, env, showCode), done: false }
  return entry
}

const waitForCode = async (entry: LoginFlow, codeWaitMs: number): Promise<void> => {
  const deadline = Date.now() + codeWaitMs
  while (entry.flow.state === "starting" && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 100))
  }
}
