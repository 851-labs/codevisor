import { randomUUID } from "node:crypto"

import {
  cancelMuseLogin,
  handshake,
  logoutMuse,
  spawnMuseClient,
  startMuseLogin,
  type MuseClient,
  type MuseConnector
} from "@codevisor/adapter-muse"
import type { HarnessAccount, HarnessAuthFlow } from "@codevisor/api"
import type { CodevisorDatabaseService, HarnessAccountRecord } from "@codevisor/db"

import type { HarnessAuthCore } from "./harness-auth-core.js"
import { run } from "./harness-auth-support.js"
import { MUSE_HARNESS_ID } from "./muse-credentials.js"
import type { SharedAccountIntegration } from "./shared-account-integration.js"

export { MUSE_HARNESS_ID }

export type MuseAuthCore = Pick<
  HarnessAuthCore,
  "accountEnv" | "executable" | "profilePath" | "emit"
> & {
  readonly config: {
    readonly sharedAccounts?: () =>
      | Pick<SharedAccountIntegration, "captureLogin" | "loginFailed" | "saveApiKey">
      | undefined
    readonly db: Pick<CodevisorDatabaseService, "setActiveHarnessAccount">
  }
}

export const makeMuseAuth = (
  core: MuseAuthCore,
  probeAccount: (accountId: string, force: boolean) => Promise<HarnessAccount>,
  connector: MuseConnector = spawnMuseClient,
  loginDeadlineMs = 10 * 60_000
) => {
  const logins = new Map<
    string,
    { accountId: string; client: MuseClient; stop: (outcome: string) => void }
  >()

  const open = async (account: HarnessAccountRecord): Promise<MuseClient> => {
    const env = await core.accountEnv(account)
    const client = await connector({
      command: await core.executable(MUSE_HARNESS_ID),
      args: ["--no-session-log"],
      cwd: core.profilePath(account) ?? env.HOME ?? process.cwd(),
      env
    })
    try {
      await handshake(client)
    } catch (cause) {
      client.close()
      throw cause
    }
    return client
  }

  const signedIn = async (account: HarnessAccountRecord): Promise<boolean> => {
    const shared = core.config.sharedAccounts?.()
    if (shared) {
      await shared.captureLogin(account.id)
      return true
    }
    const result = await probeAccount(account.id, true)
    const ok = result.authState === "authenticated" || result.authState === "notRequired"
    if (ok) await run(core.config.db.setActiveHarnessAccount(account.harnessId, account.id))
    return ok
  }

  const loginFailed = async (accountId: string): Promise<void> => {
    await core.config.sharedAccounts?.()?.loginFailed(accountId)
  }

  const cancel = async (flowId: string): Promise<void> => {
    const login = logins.get(flowId)
    if (login === undefined) return
    logins.delete(flowId)
    login.stop("cancelled")
    await cancelMuseLogin(login.client).catch(() => undefined)
    login.client.close()
    await loginFailed(login.accountId)
  }

  const begin = async (
    account: HarnessAccountRecord,
    methodId: string | undefined,
    apiKey: string | undefined
  ): Promise<HarnessAuthFlow> => {
    for (const [flowId, login] of logins) if (login.accountId === account.id) await cancel(flowId)
    const id = randomUUID()
    if (methodId === "apiKey") {
      const key = apiKey?.trim()
      if (key === undefined || key.length === 0) throw new Error("API key is required")
      const shared = core.config.sharedAccounts?.()
      if (shared) {
        await shared.saveApiKey(account.id, key)
        return { id, accountId: account.id, kind: "complete" }
      }
      const client = await open(account)
      try {
        await startMuseLogin(client, { type: "apiKey", apiKey: key })
      } finally {
        client.close()
      }
      if (!(await signedIn(account))) throw new Error("Muse Code couldn't verify that API key.")
      return { id, accountId: account.id, kind: "complete" }
    }
    const client = await open(account)
    let login: Awaited<ReturnType<typeof startMuseLogin>>
    try {
      login = await startMuseLogin(client, { type: "deviceCode" })
    } catch (cause) {
      client.close()
      throw cause
    }
    const stopped = Promise.withResolvers<{ outcome: string }>()
    logins.set(id, {
      accountId: account.id,
      client,
      stop: (outcome) => stopped.resolve({ outcome })
    })
    const deadline = setTimeout(() => stopped.resolve({ outcome: "expired" }), loginDeadlineMs)
    void (async () => {
      const { outcome } = await Promise.race([login.completed, stopped.promise])
      clearTimeout(deadline)
      if (!logins.delete(id)) return
      if (outcome === "expired") await cancelMuseLogin(client).catch(() => undefined)
      client.close()
      const success = await (
        outcome === "granted" ? signedIn(account) : Promise.resolve(false)
      ).catch(() => false)
      if (!success) await loginFailed(account.id).catch(() => undefined)
      core.emit({
        kind: "harness.authFlow.updated",
        subjectId: MUSE_HARNESS_ID,
        payload: { id, accountId: account.id, completed: true, success }
      })
    })()
    const flow: HarnessAuthFlow = {
      id,
      accountId: account.id,
      kind: "deviceCode",
      verificationUrl: login.verificationUrl ?? "https://dev.meta.ai",
      userCode: login.userCode ?? ""
    }
    core.emit({ kind: "harness.authFlow.updated", subjectId: MUSE_HARNESS_ID, payload: flow })
    return flow
  }

  const logout = async (account: HarnessAccountRecord): Promise<void> => {
    const client = await open(account)
    try {
      await logoutMuse(client)
    } finally {
      client.close()
    }
  }

  return { begin, cancel, logout }
}

export type MuseAuth = ReturnType<typeof makeMuseAuth>
