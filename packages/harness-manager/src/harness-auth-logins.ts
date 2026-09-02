import { spawnCodexClient } from "@codevisor/adapter-codex"
import type { HarnessAccount, HarnessAuthFlow } from "@codevisor/api"
import type { HarnessAccountRecord } from "@codevisor/db"
import { chmod, mkdir, rm, writeFile } from "node:fs/promises"
import { randomUUID } from "node:crypto"
import { join } from "node:path"
import type { HarnessAuthCore } from "./harness-auth-core.js"
import type { HarnessAuthProbes } from "./harness-auth-probes.js"
import { run, runWithInput } from "./harness-auth-support.js"
import type { HarnessAuthManager } from "./harness-auth-types.js"

export type HarnessLoginOperations = Pick<
  HarnessAuthManager,
  "answerLogin" | "beginLogin" | "cancelLogin" | "logout"
>

/// Interactive sign-in and sign-out per harness family: Codex browser/device
/// flows, Claude's paste-code OAuth, API-key logins, and ACP authentication.
export const makeHarnessLoginOperations = (
  core: HarnessAuthCore,
  probes: HarnessAuthProbes
): HarnessLoginOperations => {
  const {
    accountCommand,
    accountEnv,
    acpLoginMethods,
    apiKeyPath,
    claudeLogins,
    codexLogins,
    config,
    contextFor,
    emit,
    environment,
    executable,
    persistProbe,
    profilePath,
    runExecFile,
    spawnClaudeAuth
  } = core
  const { probeAccount } = probes

  const initializeCodexClient = async (account: HarnessAccountRecord) => {
    const command = await executable("codex")
    const client = await spawnCodexClient({
      command,
      cwd: profilePath(account) ?? (await environment()).HOME ?? process.cwd(),
      env: await accountEnv(account)
    })
    await client.request("initialize", {
      capabilities: { experimentalApi: true },
      clientInfo: { name: "Codevisor", title: "Codevisor", version: "0.1.0" }
    })
    client.notify("initialized")
    return client
  }

  const beginCodexLogin = async (
    account: HarnessAccountRecord,
    methodId?: string
  ): Promise<HarnessAuthFlow> => {
    const client = await initializeCodexClient(account)
    const requested =
      methodId ?? (config.preferDeviceCode === true ? "chatgptDeviceCode" : "chatgpt")
    const response = await client.request<{
      loginId?: string
      authUrl?: string
      verificationUrl?: string
      userCode?: string
    }>("account/login/start", { type: requested })
    const flowId = response.loginId ?? randomUUID()
    codexLogins.set(flowId, {
      accountId: account.id,
      client,
      ...(response.loginId === undefined ? {} : { loginId: response.loginId })
    })
    client.onNotification((method, params) => {
      if (method !== "account/login/completed") return
      const payload = params as { loginId?: string; success?: boolean; error?: string | null }
      if (payload.loginId !== undefined && payload.loginId !== response.loginId) return
      void (async () => {
        try {
          if (payload.success === true) {
            await probeAccount(account.id, true)
            await run(config.db.setActiveHarnessAccount(account.harnessId, account.id))
          } else {
            await persistProbe(account, {
              authState: "unauthenticated",
              canLogin: true,
              canLogout: false,
              detail: payload.error ?? "Codex sign-in was not completed"
            })
          }
        } finally {
          codexLogins.delete(flowId)
          client.close()
          emit({
            kind: "harness.authFlow.updated",
            subjectId: account.harnessId,
            payload: {
              id: flowId,
              accountId: account.id,
              completed: true,
              success: payload.success
            }
          })
        }
      })()
    })
    const flow: HarnessAuthFlow =
      requested === "chatgptDeviceCode"
        ? {
            id: flowId,
            accountId: account.id,
            kind: "deviceCode",
            verificationUrl: response.verificationUrl ?? "https://auth.openai.com/codex/device",
            userCode: response.userCode ?? ""
          }
        : {
            id: flowId,
            accountId: account.id,
            kind: "browser",
            url: response.authUrl ?? ""
          }
    emit({ kind: "harness.authFlow.updated", subjectId: account.harnessId, payload: flow })
    return flow
  }

  const beginClaudeLogin = async (account: HarnessAccountRecord): Promise<HarnessAuthFlow> => {
    // Native wrap of Claude's OAuth (Phase: replace the PTY login): the SDK
    // yields the browser URL up front and takes the pasted code back — no
    // terminal rendering, real input affordances on the client.
    const env = await accountEnv(account)
    const client = spawnClaudeAuth({
      claudePath: await executable("claude-code"),
      cwd: profilePath(account) ?? env.HOME ?? process.cwd(),
      env
    })
    try {
      const { url } = await client.start()
      const flowId = randomUUID()
      claudeLogins.set(flowId, { accountId: account.id, client })
      const flow: HarnessAuthFlow = { id: flowId, accountId: account.id, kind: "pasteCode", url }
      emit({ kind: "harness.authFlow.updated", subjectId: account.harnessId, payload: flow })
      return flow
    } catch (cause) {
      client.close()
      throw cause
    }
  }

  /// Completes a pasteCode flow with the code the user pasted back.
  const answerLogin = async (flowId: string, code: string): Promise<HarnessAuthFlow> => {
    const entry = claudeLogins.get(flowId)
    if (entry === undefined) throw new Error("This sign-in attempt has expired — start again")
    const account = await run(config.db.getHarnessAccount(entry.accountId))
    if (account === undefined) throw new Error("Harness account not found")
    try {
      await entry.client.submit(code)
    } finally {
      claudeLogins.delete(flowId)
      entry.client.close()
    }
    const probed = await probeAccount(account.id, true)
    if (probed.authState === "authenticated" || probed.authState === "notRequired") {
      await run(config.db.setActiveHarnessAccount(account.harnessId, account.id))
    }
    const done: HarnessAuthFlow = { id: flowId, accountId: account.id, kind: "complete" }
    emit({ kind: "harness.authFlow.updated", subjectId: account.harnessId, payload: done })
    return done
  }

  const beginApiKeyLogin = async (
    account: HarnessAccountRecord,
    rawApiKey: string | undefined
  ): Promise<HarnessAuthFlow> => {
    const apiKey = rawApiKey?.trim()
    if (apiKey === undefined || apiKey.length === 0) throw new Error("API key is required")
    const suffix = apiKey.slice(-4)
    if (account.harnessId === "codex") {
      const command = await executable("codex")
      await runWithInput(
        command,
        ["login", "--with-api-key"],
        apiKey,
        await accountEnv(account),
        profilePath(account) ?? (await environment()).HOME ?? process.cwd()
      )
    } else if (account.harnessId === "claude-code") {
      const path = apiKeyPath(account)
      const directory = join(path, "..")
      await mkdir(directory, { recursive: true, mode: 0o700 })
      await chmod(directory, 0o700)
      await writeFile(path, `${apiKey}\n`, { encoding: "utf8", mode: 0o600 })
      await chmod(path, 0o600)
    } else {
      throw new Error("API-key authentication is not supported for this harness")
    }
    await run(
      config.db.updateHarnessAccountAuth(account.id, {
        authState: "checking",
        authMethod: "apiKey",
        label: `API key ••••${suffix}`,
        canLogin: true,
        canLogout: true,
        detail: null
      })
    )
    const result = await probeAccount(account.id, true)
    if (result.authState !== "authenticated" && result.authState !== "notRequired") {
      throw new Error(result.detail ?? "The API key could not be verified")
    }
    await run(config.db.setActiveHarnessAccount(account.harnessId, account.id))
    return { id: randomUUID(), accountId: account.id, kind: "complete" }
  }

  const beginLogin = async (
    accountId: string,
    methodId?: string,
    apiKey?: string
  ): Promise<HarnessAuthFlow> => {
    const account = await run(config.db.getHarnessAccount(accountId))
    if (account === undefined) throw new Error(`Harness account not found: ${accountId}`)
    if (methodId === "apiKey") return beginApiKeyLogin(account, apiKey)
    if (account.harnessId === "codex") return beginCodexLogin(account, methodId)
    if (account.harnessId === "claude-code") return beginClaudeLogin(account)
    if (account.harnessId === "pi") {
      throw new Error("Choose and authenticate a Pi provider in Codevisor settings")
    }
    const methods = acpLoginMethods.get(account.harnessId) ?? []
    const selectedMethod = methodId ?? methods[0]?.id
    if (selectedMethod === undefined) {
      throw new Error("This ACP agent does not advertise an authentication method")
    }
    await run(
      config.agents.authenticateHarness(
        account.harnessId,
        selectedMethod,
        await contextFor(account)
      )
    )
    const result = await probeAccount(account.id, true)
    if (result.authState === "authenticated" || result.authState === "notRequired") {
      await run(config.db.setActiveHarnessAccount(account.harnessId, account.id))
    }
    const flow: HarnessAuthFlow = {
      id: randomUUID(),
      accountId: account.id,
      kind: "complete"
    }
    emit({ kind: "harness.authFlow.updated", subjectId: account.harnessId, payload: flow })
    return flow
  }

  const cancelLogin = async (flowId: string): Promise<void> => {
    const codex = codexLogins.get(flowId)
    if (codex !== undefined) {
      if (codex.loginId !== undefined) {
        await codex.client.request("account/login/cancel", { loginId: codex.loginId })
      }
      codex.client.close()
      codexLogins.delete(flowId)
      return
    }
    const claude = claudeLogins.get(flowId)
    if (claude !== undefined) {
      claude.client.close()
      claudeLogins.delete(flowId)
      return
    }
  }

  const logout = async (accountId: string): Promise<HarnessAccount> => {
    const account = await run(config.db.getHarnessAccount(accountId))
    if (account === undefined) throw new Error(`Harness account not found: ${accountId}`)
    await rm(apiKeyPath(account), { force: true })
    if (account.harnessId === "codex") {
      const client = await initializeCodexClient(account)
      try {
        await client.request("account/logout")
      } finally {
        client.close()
      }
    } else if (account.harnessId === "claude-code") {
      const command = await executable("claude-code")
      const execution = await accountCommand(account)
      await runExecFile(command, ["auth", "logout"], {
        cwd: execution.cwd,
        env: execution.env,
        timeout: 30_000
      })
    } else {
      await run(config.agents.logoutHarness(account.harnessId, await contextFor(account)))
    }
    return probeAccount(accountId, true)
  }

  return { answerLogin, beginLogin, cancelLogin, logout }
}
