import { spawnCodexClient } from "@codevisor/adapter-codex"
import type { HarnessAccount } from "@codevisor/api"
import type { HarnessAccountRecord } from "@codevisor/db"
import type { HarnessAuthCore } from "./harness-auth-core.js"
import {
  AUTH_CACHE_MS,
  CODEX_PROBE_TIMEOUT_MS,
  parseClaudeAuthStatus,
  run,
  withTimeout,
  type ClaudeAuthStatus
} from "./harness-auth-support.js"

/// Sign-in status probes per harness family: Codex over its app-server
/// protocol, Claude via `auth status --json`, everything else through the
/// runtime's ACP authentication inspection.
export const makeHarnessAuthProbes = (core: HarnessAuthCore) => {
  const {
    accountCommand,
    accountEnv,
    acpLoginMethods,
    config,
    contextFor,
    environment,
    executable,
    persistProbe,
    probes,
    profilePath,
    publicAccount,
    runExecFile
  } = core

  const probeCodex = async (account: HarnessAccountRecord): Promise<HarnessAccount> => {
    const command = await executable("codex")
    const client = await spawnCodexClient({
      command,
      cwd: profilePath(account) ?? (await environment()).HOME ?? process.cwd(),
      env: await accountEnv(account)
    })
    try {
      const deadline = Date.now() + CODEX_PROBE_TIMEOUT_MS
      const requestBeforeDeadline = <A>(operation: Promise<A>): Promise<A> =>
        withTimeout(operation, Math.max(1, deadline - Date.now()), "Codex sign-in check timed out")
      await requestBeforeDeadline(
        client.request("initialize", {
          capabilities: { experimentalApi: true },
          clientInfo: { name: "Codevisor", title: "Codevisor", version: "0.1.0" }
        })
      )
      client.notify("initialized")
      const response = await requestBeforeDeadline(
        client.request<{
          account?: null | {
            type?: string
            email?: string | null
            planType?: string | null
          }
          requiresOpenaiAuth?: boolean
        }>("account/read", { refreshToken: false })
      )
      if (response.account === null || response.account === undefined) {
        const notRequired = response.requiresOpenaiAuth === false
        return persistProbe(account, {
          authState: notRequired ? "notRequired" : "unauthenticated",
          authMethod: null,
          email: null,
          canLogin: true,
          canLogout: false,
          detail: null
        })
      }
      const type = response.account.type ?? "codex"
      return persistProbe(account, {
        authState: "authenticated",
        authMethod: type,
        email: response.account.email ?? null,
        canLogin: true,
        canLogout: true,
        ...(response.account.email ? { label: response.account.email } : {}),
        detail: response.account.planType ?? null
      })
    } finally {
      client.close()
    }
  }

  const probeClaude = async (account: HarnessAccountRecord): Promise<HarnessAccount> => {
    const command = await executable("claude-code")
    try {
      const execution = await accountCommand(account)
      const result = await runExecFile(command, ["auth", "status", "--json"], {
        cwd: execution.cwd,
        env: execution.env,
        timeout: 10_000,
        maxBuffer: 1024 * 1024
      })
      const status = JSON.parse(result.stdout) as ClaudeAuthStatus
      if (status.loggedIn !== true) {
        return persistProbe(account, {
          authState: "unauthenticated",
          authMethod: status.authMethod ?? null,
          email: status.email ?? null,
          organizationId: status.orgId ?? null,
          canLogin: true,
          canLogout: false,
          detail: null
        })
      }
      return persistProbe(account, {
        authState: "authenticated",
        authMethod: status.authMethod ?? "claude.ai",
        email: status.email ?? null,
        organizationId: status.orgId ?? null,
        canLogin: true,
        canLogout: true,
        ...(status.email !== undefined ? { label: status.email } : {}),
        ...(status.apiKeySource === undefined ? {} : { authMethod: "apiKey" }),
        detail: null
      })
    } catch (cause) {
      const error = cause as { stdout?: string; stderr?: string; code?: number | string }
      const output = `${error.stdout ?? ""}${error.stderr ?? ""}`.toLowerCase()
      const status = parseClaudeAuthStatus(error.stdout)
      const signedOut =
        status?.loggedIn === false ||
        output.includes("not logged in") ||
        /"loggedin"\s*:\s*false/.test(output)
      return persistProbe(account, {
        authState: signedOut ? "unauthenticated" : "error",
        ...(status?.authMethod === undefined ? {} : { authMethod: status.authMethod }),
        ...(status?.email === undefined ? {} : { email: status.email }),
        ...(status?.orgId === undefined ? {} : { organizationId: status.orgId }),
        canLogin: true,
        canLogout: false,
        detail: signedOut
          ? null
          : `Unable to check Claude sign-in${
              error.code === undefined ? "" : ` (Claude exited with status ${error.code})`
            }`
      })
    }
  }

  const probeRecord = async (
    account: HarnessAccountRecord,
    force = false
  ): Promise<HarnessAccount> => {
    if (!force && account.lastCheckedAt !== undefined) {
      const age = Date.now() - Date.parse(account.lastCheckedAt)
      if (Number.isFinite(age) && age < AUTH_CACHE_MS) return publicAccount(account)
    }
    if (account.harnessId === "codex") return probeCodex(account)
    if (account.harnessId === "claude-code") return probeClaude(account)
    const inspection = await run(
      config.agents.probeHarnessAuth(account.harnessId, await contextFor(account))
    )
    const methods = inspection.methods.map((method) => ({
      ...method,
      kind: "agent" as const
    }))
    acpLoginMethods.set(account.harnessId, methods)
    return persistProbe(account, {
      authState: inspection.state,
      authMethod: null,
      canLogin: methods.length > 0,
      canLogout: inspection.canLogout,
      detail: inspection.detail ?? null
    })
  }

  const probeAccount = async (accountId: string, force = false): Promise<HarnessAccount> => {
    const current = probes.get(accountId)
    if (current !== undefined) return current
    const pending = (async () => {
      const account = await run(config.db.getHarnessAccount(accountId))
      if (account === undefined) throw new Error(`Harness account not found: ${accountId}`)
      return probeRecord(account, force)
    })().finally(() => probes.delete(accountId))
    probes.set(accountId, pending)
    return pending
  }

  return { probeAccount }
}

export type HarnessAuthProbes = ReturnType<typeof makeHarnessAuthProbes>
