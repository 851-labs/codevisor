import { spawn } from "node:child_process"
import { randomUUID } from "node:crypto"
import { chmod, mkdir, rm, writeFile } from "node:fs/promises"
import { join } from "node:path"

import { spawnCodexClient } from "@codevisor/adapter-codex"
import type { HarnessAccount, HarnessAuthFlow } from "@codevisor/api"
import type { HarnessAccountRecord } from "@codevisor/db"

import type { GrokAuth } from "./grok-auth.js"
import type { HarnessAuthCore } from "./harness-auth-core.js"
import type { HarnessAuthProbes } from "./harness-auth-probes.js"
import {
  CURSOR_LOGIN_URL_TIMEOUT_MS,
  parseCursorLoginUrl,
  run,
  runWithInput,
  withTimeout
} from "./harness-auth-support.js"
import type { HarnessAuthManager } from "./harness-auth-types.js"

export type HarnessLoginOperations = Pick<
  HarnessAuthManager,
  "answerLogin" | "beginLogin" | "cancelLogin" | "logout"
>

/// Interactive sign-in and sign-out per harness family: Codex browser/device
/// flows, Claude's paste-code OAuth, API-key logins, and ACP authentication.
export const makeHarnessLoginOperations = (
  core: HarnessAuthCore,
  probes: HarnessAuthProbes,
  grok: GrokAuth
): HarnessLoginOperations => {
  const {
    accountCommand,
    accountEnv,
    acpLoginMethods,
    announce,
    apiKeyPath,
    claudeLogins,
    codexLogins,
    cursorLogins,
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
        let success = payload.success === true
        try {
          if (success) {
            if (client.closeAndWait) await client.closeAndWait()
            else client.close()
            const shared = config.sharedAccounts?.()
            if (shared) await shared.captureLogin(account.id)
            else {
              await probeAccount(account.id, true)
              await run(config.db.setActiveHarnessAccount(account.harnessId, account.id))
            }
          } else throw new Error("Codex sign-in was not completed")
        } catch {
          success = false
          await config.sharedAccounts?.()?.loginFailed(account.id)
          await persistProbe(account, {
            authState: "error",
            canLogin: true,
            canLogout: false,
            detail: "Sign-in could not be saved. Try signing in again."
          })
        } finally {
          codexLogins.delete(flowId)
          client.close()
          emit({
            kind: "harness.authFlow.updated",
            subjectId: account.harnessId,
            payload: { id: flowId, accountId: account.id, completed: true, success }
          })
        }
      })().catch(() => undefined)
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

  /// Cursor's CLI owns the whole OAuth: with `NO_OPEN_BROWSER` it prints the
  /// URL and stays resident until the browser round-trip completes, then
  /// writes credentials and exits. Codevisor surfaces that URL so the client
  /// opens it locally — a remote machine's sign-in still lands in the user's
  /// own browser — and the client's existing poll notices the result.
  const beginCursorLogin = async (account: HarnessAccountRecord): Promise<HarnessAuthFlow> => {
    const command = await executable("cursor")
    const execution = await accountCommand(account)
    const child = spawn(command, ["login"], {
      cwd: execution.cwd,
      env: { ...execution.env, NO_OPEN_BROWSER: "1" },
      stdio: ["ignore", "pipe", "pipe"]
    })
    const flowId = randomUUID()
    cursorLogins.set(flowId, { accountId: account.id, child })
    try {
      const url = await withTimeout(
        new Promise<string>((resolve, reject) => {
          let output = ""
          const read = (chunk: string) => {
            output += chunk
            const found = parseCursorLoginUrl(output)
            if (found !== undefined) resolve(found)
          }
          child.stdout?.setEncoding("utf8")
          child.stderr?.setEncoding("utf8")
          child.stdout?.on("data", read)
          child.stderr?.on("data", read)
          child.once("error", reject)
          child.once("exit", (code) => {
            reject(
              new Error(
                parseCursorLoginUrl(output) === undefined && code !== 0
                  ? output.trim() || `cursor-agent login exited with status ${code}`
                  : "cursor-agent login ended before it produced a sign-in link"
              )
            )
          })
        }),
        CURSOR_LOGIN_URL_TIMEOUT_MS,
        "Cursor sign-in did not start"
      )
      const flow: HarnessAuthFlow = { id: flowId, accountId: account.id, kind: "browser", url }
      emit({ kind: "harness.authFlow.updated", subjectId: account.harnessId, payload: flow })
      return flow
    } catch (cause) {
      cursorLogins.delete(flowId)
      child.kill()
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
    } catch (cause) {
      await config.sharedAccounts?.()?.loginFailed(account.id)
      throw cause
    } finally {
      claudeLogins.delete(flowId)
      entry.client.close()
    }
    try {
      const shared = config.sharedAccounts?.()
      if (shared) await shared.captureLogin(account.id)
      else {
        const probed = await probeAccount(account.id, true)
        if (probed.authState === "authenticated" || probed.authState === "notRequired") {
          await run(config.db.setActiveHarnessAccount(account.harnessId, account.id))
        }
      }
    } catch (cause) {
      await config.sharedAccounts?.()?.loginFailed(account.id)
      throw cause
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
    const shared = config.sharedAccounts?.()
    if (shared) await shared.saveApiKey(account.id, apiKey)
    else await run(config.db.setActiveHarnessAccount(account.harnessId, account.id))
    return { id: randomUUID(), accountId: account.id, kind: "complete" }
  }

  const beginLogin = async (
    accountId: string,
    methodId?: string,
    apiKey?: string,
    shared = false
  ): Promise<HarnessAuthFlow> => {
    accountId = (await config.sharedAccounts?.()?.prepareLogin(accountId, methodId)) ?? accountId
    const account = await run(config.db.getHarnessAccount(accountId))
    if (account === undefined) throw new Error(`Harness account not found: ${accountId}`)
    if (account.harnessId === "grok-build") return grok.begin(account, methodId, apiKey, shared)
    if (methodId === "apiKey") return beginApiKeyLogin(account, apiKey)
    if (
      account.harnessId === "codex" ||
      account.harnessId === "claude-code" ||
      account.harnessId === "cursor"
    ) {
      try {
        return await (account.harnessId === "codex"
          ? beginCodexLogin(account, methodId)
          : account.harnessId === "claude-code"
            ? beginClaudeLogin(account)
            : beginCursorLogin(account))
      } catch (cause) {
        await config.sharedAccounts?.()?.loginFailed(account.id)
        throw cause
      }
    }
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
    await grok.cancel(flowId)
    const codex = codexLogins.get(flowId)
    if (codex !== undefined) {
      if (codex.loginId !== undefined) {
        await codex.client.request("account/login/cancel", { loginId: codex.loginId })
      }
      codex.client.close()
      codexLogins.delete(flowId)
      await config.sharedAccounts?.()?.loginFailed(codex.accountId)
      return
    }
    const cursor = cursorLogins.get(flowId)
    if (cursor !== undefined) {
      cursorLogins.delete(flowId)
      cursor.child.kill()
      await config.sharedAccounts?.()?.loginFailed(cursor.accountId)
      return
    }
    const claude = claudeLogins.get(flowId)
    if (claude !== undefined) {
      claude.client.close()
      claudeLogins.delete(flowId)
      await config.sharedAccounts?.()?.loginFailed(claude.accountId)
      return
    }
  }

  const logout = async (accountId: string, sharedScope = false): Promise<HarnessAccount> => {
    const account = await run(config.db.getHarnessAccount(accountId))
    // A shared sign-out settles its own state without a probe; announce it so
    // every mounted catalog — not just the client that clicked — follows.
    const shared = await config.sharedAccounts?.()?.logout(accountId)
    if (shared !== undefined) return announce(account, shared)
    if (account === undefined) throw new Error(`Harness account not found: ${accountId}`)
    if (account.harnessId === "grok-build") return grok.logout(account, sharedScope)
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
    } else if (account.harnessId === "cursor") {
      const command = await executable("cursor")
      const execution = await accountCommand(account)
      await runExecFile(command, ["logout"], {
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
