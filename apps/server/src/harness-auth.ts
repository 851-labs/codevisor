import {
  harnessCatalog,
  locateExecutableOnPath,
  resolveShellEnv,
  spawnCodexClient,
  type AgentRuntimeService,
  type HarnessAccountContext
} from "@codevisor/agent-runtime"
import type {
  Harness,
  HarnessAccount,
  HarnessAuth,
  HarnessAuthFlow,
  HarnessAuthMethod
} from "@codevisor/api"
import type {
  HarnessAccountRecord,
  CodevisorDatabaseService,
  UpdateHarnessAccountAuthRequest
} from "@codevisor/db"
import type { TerminalManagerService } from "@codevisor/terminal"
import { execFile } from "node:child_process"
import { spawn } from "node:child_process"
import { chmod, mkdir, readFile, rm, writeFile } from "node:fs/promises"
import { randomUUID } from "node:crypto"
import { join } from "node:path"
import { promisify } from "node:util"
import { Effect } from "effect"

const execFileAsync = promisify(execFile)
const AUTH_CACHE_MS = 30_000
const CLAUDE_AUTH_OVERRIDE_ENV_VARS = [
  "ANTHROPIC_API_KEY",
  "ANTHROPIC_AUTH_TOKEN",
  "CLAUDE_CODE_OAUTH_TOKEN",
  "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
  "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR"
] as const

type AuthEventKind = "harness.auth.updated" | "harness.account.updated" | "harness.authFlow.updated"

export interface HarnessAuthEvent {
  readonly kind: AuthEventKind
  readonly subjectId: string
  readonly payload: unknown
}

export interface HarnessAuthManagerConfig {
  readonly dataDir: string
  readonly db: CodevisorDatabaseService
  readonly agents: AgentRuntimeService
  readonly terminal: TerminalManagerService
  readonly preferDeviceCode?: boolean
}

export interface HarnessAuthManager {
  readonly decorateHarnesses: (
    harnesses: ReadonlyArray<Harness>,
    force?: boolean
  ) => Promise<ReadonlyArray<Harness>>
  readonly refresh: (harnessId?: string) => Promise<void>
  readonly accounts: (harnessId: string) => Promise<ReadonlyArray<HarnessAccount>>
  readonly createAccount: (harnessId: string, label?: string) => Promise<HarnessAccount>
  readonly renameAccount: (accountId: string, label: string) => Promise<HarnessAccount>
  readonly removeAccount: (accountId: string) => Promise<void>
  readonly activateAccount: (harnessId: string, accountId: string) => Promise<void>
  readonly probeAccount: (accountId: string, force?: boolean) => Promise<HarnessAccount>
  readonly beginLogin: (
    accountId: string,
    methodId?: string,
    apiKey?: string
  ) => Promise<HarnessAuthFlow>
  readonly cancelLogin: (flowId: string) => Promise<void>
  readonly logout: (accountId: string) => Promise<HarnessAccount>
  readonly accountContext: (accountId: string) => Promise<HarnessAccountContext>
  readonly activeAccountContext: (harnessId: string) => Promise<HarnessAccountContext | undefined>
  readonly markAccountExpired: (accountId: string, detail?: string) => Promise<void>
  readonly subscribe: (listener: (event: HarnessAuthEvent) => void) => () => void
}

interface CodexLoginEntry {
  readonly accountId: string
  readonly client: Awaited<ReturnType<typeof spawnCodexClient>>
  readonly loginId?: string
}

interface TerminalLoginEntry {
  readonly accountId: string
  readonly terminalId: string
}

const run = <A>(effect: Effect.Effect<A, unknown>): Promise<A> => Effect.runPromise(effect)

export const makeHarnessAuthManager = (config: HarnessAuthManagerConfig): HarnessAuthManager => {
  const listeners = new Set<(event: HarnessAuthEvent) => void>()
  const probes = new Map<string, Promise<HarnessAccount>>()
  const codexLogins = new Map<string, CodexLoginEntry>()
  const terminalLogins = new Map<string, TerminalLoginEntry>()
  const acpLoginMethods = new Map<string, ReadonlyArray<HarnessAuthMethod>>()
  let environmentPromise: Promise<NodeJS.ProcessEnv> | undefined

  const emit = (event: HarnessAuthEvent): void => {
    for (const listener of listeners) listener(event)
  }

  const environment = (): Promise<NodeJS.ProcessEnv> => {
    environmentPromise ??= resolveShellEnv().finally(() => {
      environmentPromise = undefined
    })
    return environmentPromise
  }

  const publicAccount = (record: HarnessAccountRecord): HarnessAccount => {
    const {
      profileKey: _profileKey,
      createdAt: _createdAt,
      updatedAt: _updatedAt,
      ...account
    } = record
    return account
  }

  const definition = (harnessId: string) => {
    const value = harnessCatalog.find((candidate) => candidate.id === harnessId)
    if (value === undefined) throw new Error(`Unknown harness: ${harnessId}`)
    return value
  }

  const profilePath = (account: HarnessAccountRecord): string | undefined =>
    account.profileKind === "managed"
      ? join(
          config.dataDir,
          "harness-profiles",
          account.harnessId,
          account.profileKey ?? account.id
        )
      : undefined

  const apiKeyPath = (account: HarnessAccountRecord): string =>
    join(config.dataDir, "harness-secrets", account.harnessId, account.id, "api-key")

  const storedApiKey = async (account: HarnessAccountRecord): Promise<string | undefined> => {
    try {
      return (await readFile(apiKeyPath(account), "utf8")).trim() || undefined
    } catch (cause) {
      if ((cause as NodeJS.ErrnoException).code === "ENOENT") return undefined
      throw cause
    }
  }

  const contextFor = async (account: HarnessAccountRecord): Promise<HarnessAccountContext> => {
    const path = profilePath(account)
    if (path !== undefined) {
      await mkdir(path, { recursive: true, mode: 0o700 })
      await chmod(path, 0o700)
    }
    const env: Record<string, string> = {}
    if (path !== undefined && account.harnessId === "codex") env.CODEX_HOME = path
    if (path !== undefined && account.harnessId === "claude-code") env.CLAUDE_CONFIG_DIR = path
    const apiKey = await storedApiKey(account)
    if (apiKey !== undefined) {
      if (account.harnessId === "codex") env.OPENAI_API_KEY = apiKey
      if (account.harnessId === "claude-code") env.ANTHROPIC_API_KEY = apiKey
    }
    return {
      id: account.id,
      profileKind: account.profileKind,
      ...(path === undefined ? {} : { profilePath: path }),
      ...(Object.keys(env).length === 0 ? {} : { env })
    }
  }

  const executable = async (harnessId: string): Promise<string> => {
    const env = await environment()
    const entry = definition(harnessId)
    for (const candidate of [...entry.detectBinaries, ...(entry.fallbackPaths ?? [])]) {
      const located = locateExecutableOnPath(candidate, env)
      if (located !== undefined) return located
    }
    throw new Error(`${entry.name} is not installed`)
  }

  const accountEnv = async (account: HarnessAccountRecord): Promise<NodeJS.ProcessEnv> => {
    const base = { ...(await environment()) }
    const accountContext = await contextFor(account)
    if (account.profileKind === "managed" && account.harnessId === "claude-code") {
      for (const name of CLAUDE_AUTH_OVERRIDE_ENV_VARS) delete base[name]
    }
    return { ...base, ...accountContext.env }
  }

  const persistProbe = async (
    account: HarnessAccountRecord,
    update: UpdateHarnessAccountAuthRequest
  ): Promise<HarnessAccount> => {
    const saved = await run(config.db.updateHarnessAccountAuth(account.id, update))
    const value = publicAccount(saved)
    emit({ kind: "harness.account.updated", subjectId: account.harnessId, payload: value })
    emit({ kind: "harness.auth.updated", subjectId: account.harnessId, payload: value })
    return value
  }

  const probeCodex = async (account: HarnessAccountRecord): Promise<HarnessAccount> => {
    const command = await executable("codex")
    const client = await spawnCodexClient({
      command,
      cwd: profilePath(account) ?? (await environment()).HOME ?? process.cwd(),
      env: await accountEnv(account)
    })
    try {
      await client.request("initialize", {
        capabilities: { experimentalApi: true },
        clientInfo: { name: "Codevisor", title: "Codevisor", version: "0.1.0" }
      })
      client.notify("initialized")
      const response = await client.request<{
        account?: null | {
          type?: string
          email?: string | null
          planType?: string | null
        }
        requiresOpenaiAuth?: boolean
      }>("account/read", { refreshToken: false })
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
      const result = await execFileAsync(command, ["auth", "status", "--json"], {
        env: await accountEnv(account),
        timeout: 10_000,
        maxBuffer: 1024 * 1024
      })
      const status = JSON.parse(result.stdout) as {
        loggedIn?: boolean
        authMethod?: string
        apiKeySource?: string
        email?: string
        orgId?: string
      }
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
      const signedOut =
        error.code === 1 || output.includes("not logged in") || output.includes('loggedin":false')
      return persistProbe(account, {
        authState: signedOut ? "unauthenticated" : "error",
        canLogin: true,
        canLogout: false,
        detail: signedOut ? null : "Unable to check Claude sign-in"
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

  const ensureDefault = async (harness: Harness): Promise<HarnessAccountRecord> => {
    const existing = (await run(config.db.listHarnessAccounts(harness.id))).find(
      (account) => account.profileKind === "default"
    )
    if (existing !== undefined) return existing
    return run(
      config.db.saveHarnessAccount({
        harnessId: harness.id,
        profileKind: "default",
        label: `Existing ${harness.name} account`,
        authState: "checking",
        canLogin: harness.id === "codex" || harness.id === "claude-code",
        canLogout: false
      })
    )
  }

  const loginMethods = (harnessId: string): ReadonlyArray<HarnessAuthMethod> => {
    if (harnessId === "codex") {
      return [
        {
          id: "chatgpt",
          name: "Sign in with ChatGPT",
          kind: "browser",
          description: "Continue in your web browser."
        },
        {
          id: "chatgptDeviceCode",
          name: "Sign in with a code",
          kind: "deviceCode",
          description: "Best for a remote Codevisor server."
        },
        {
          id: "apiKey",
          name: "Sign in with OpenAI API Key",
          kind: "apiKey",
          description: "Use API billing instead of a ChatGPT subscription."
        }
      ]
    }
    if (harnessId === "claude-code") {
      return [
        {
          id: "claude-login",
          name: "Sign in to Claude",
          kind: "terminal",
          description: "Claude opens its secure browser sign-in flow."
        },
        {
          id: "apiKey",
          name: "Sign in with Anthropic API Key",
          kind: "apiKey",
          description: "Use Anthropic API billing instead of a Claude subscription."
        }
      ]
    }
    return acpLoginMethods.get(harnessId) ?? []
  }

  const authSnapshot = async (harnessId: string): Promise<HarnessAuth> => {
    const accounts = (await run(config.db.listHarnessAccounts(harnessId))).map(publicAccount)
    const active = accounts.find((account) => account.isActive) ?? accounts[0]
    return {
      state: active?.authState ?? "unavailable",
      ...(active === undefined ? {} : { activeAccountId: active.id }),
      accounts,
      loginMethods: loginMethods(harnessId),
      supportsMultipleAccounts: harnessId === "codex" || harnessId === "claude-code"
    }
  }

  const refresh = async (harnessId?: string): Promise<void> => {
    const ids = harnessId === undefined ? harnessCatalog.map((entry) => entry.id) : [harnessId]
    await Promise.all(
      ids.map(async (id) => {
        const accounts = await run(config.db.listHarnessAccounts(id))
        await Promise.all(accounts.map((account) => probeAccount(account.id, true)))
      })
    )
  }

  const decorateHarnesses = async (
    harnesses: ReadonlyArray<Harness>,
    force = false
  ): Promise<ReadonlyArray<Harness>> =>
    Promise.all(
      harnesses.map(async (harness) => {
        const desiredEnabled = harness.enabled
        if (harness.readiness.state !== "ready") {
          return { ...harness, desiredEnabled, enabled: false }
        }
        const account = await ensureDefault(harness)
        try {
          await probeAccount(account.id, force)
        } catch (cause) {
          await persistProbe(account, {
            authState: "error",
            canLogin: account.canLogin,
            canLogout: false,
            detail: cause instanceof Error ? cause.message : String(cause)
          })
        }
        const auth = await authSnapshot(harness.id)
        const usable = auth.state === "authenticated" || auth.state === "notRequired"
        return { ...harness, desiredEnabled, enabled: desiredEnabled && usable, auth }
      })
    )

  const createAccount = async (harnessId: string, label?: string): Promise<HarnessAccount> => {
    if (harnessId !== "codex" && harnessId !== "claude-code") {
      throw new Error("This harness does not support multiple managed accounts")
    }
    definition(harnessId)
    const id = randomUUID()
    const path = join(config.dataDir, "harness-profiles", harnessId, id)
    await mkdir(path, { recursive: true, mode: 0o700 })
    await chmod(path, 0o700)
    const saved = await run(
      config.db.saveHarnessAccount({
        id,
        harnessId,
        profileKind: "managed",
        profileKey: id,
        label: label?.trim() || `Account ${id.slice(0, 6)}`,
        authState: "unauthenticated",
        canLogin: true,
        canLogout: false
      })
    )
    const account = publicAccount(saved)
    emit({ kind: "harness.account.updated", subjectId: harnessId, payload: account })
    return account
  }

  const renameAccount = async (accountId: string, label: string): Promise<HarnessAccount> => {
    const account = await run(config.db.getHarnessAccount(accountId))
    if (account === undefined) throw new Error(`Harness account not found: ${accountId}`)
    const saved = await run(
      config.db.updateHarnessAccountAuth(accountId, {
        label: label.trim() || account.label,
        authState: account.authState
      })
    )
    const value = publicAccount(saved)
    emit({ kind: "harness.account.updated", subjectId: account.harnessId, payload: value })
    return value
  }

  const removeAccount = async (accountId: string): Promise<void> => {
    const account = await run(config.db.getHarnessAccount(accountId))
    if (account === undefined) throw new Error(`Harness account not found: ${accountId}`)
    const path = profilePath(account)
    await run(config.db.removeHarnessAccount(accountId))
    if (path !== undefined) await rm(path, { recursive: true, force: true })
    await rm(join(apiKeyPath(account), ".."), { recursive: true, force: true })
    emit({
      kind: "harness.account.updated",
      subjectId: account.harnessId,
      payload: { id: accountId, removed: true }
    })
  }

  const activateAccount = async (harnessId: string, accountId: string): Promise<void> => {
    const account = await probeAccount(accountId, true)
    if (account.harnessId !== harnessId) throw new Error("Account belongs to another harness")
    if (account.authState !== "authenticated" && account.authState !== "notRequired") {
      throw new Error("Sign in to this account before selecting it")
    }
    await run(config.db.setActiveHarnessAccount(harnessId, accountId))
    emit({
      kind: "harness.auth.updated",
      subjectId: harnessId,
      payload: await authSnapshot(harnessId)
    })
  }

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

  const monitorClaudeLogin = (flowId: string, accountId: string): void => {
    const startedAt = Date.now()
    const tick = async (): Promise<void> => {
      const entry = terminalLogins.get(flowId)
      if (entry === undefined) return
      try {
        const account = await probeAccount(accountId, true)
        if (account.authState === "authenticated") {
          terminalLogins.delete(flowId)
          await run(config.db.setActiveHarnessAccount(account.harnessId, account.id))
          emit({
            kind: "harness.authFlow.updated",
            subjectId: account.harnessId,
            payload: { id: flowId, accountId, completed: true, success: true }
          })
          return
        }
      } catch {
        // Keep polling while the interactive Claude login owns the terminal.
      }
      if (Date.now() - startedAt >= 10 * 60_000) {
        terminalLogins.delete(flowId)
        return
      }
      setTimeout(() => void tick(), 2_000)
    }
    setTimeout(() => void tick(), 1_000)
  }

  const beginClaudeLogin = async (account: HarnessAccountRecord): Promise<HarnessAuthFlow> => {
    const command = await executable("claude-code")
    const flowId = randomUUID()
    const terminalKey = `auth:${flowId}`
    const path = profilePath(account) ?? (await environment()).HOME ?? process.cwd()
    const terminal = await run(
      config.terminal.createTerminal(
        {
          sessionId: terminalKey,
          cwd: path,
          cols: 90,
          rows: 28,
          shell: command,
          args: ["auth", "login"]
        },
        await accountEnv(account)
      )
    )
    terminalLogins.set(flowId, { accountId: account.id, terminalId: terminal.terminalId })
    monitorClaudeLogin(flowId, account.id)
    const flow: HarnessAuthFlow = {
      id: flowId,
      accountId: account.id,
      kind: "terminal",
      terminalId: terminal.terminalId,
      terminalKey
    }
    emit({ kind: "harness.authFlow.updated", subjectId: account.harnessId, payload: flow })
    return flow
  }

  const runWithInput = async (
    command: string,
    args: ReadonlyArray<string>,
    input: string,
    env: NodeJS.ProcessEnv,
    cwd: string
  ): Promise<void> =>
    new Promise((resolve, reject) => {
      const child = spawn(command, args, { cwd, env, stdio: ["pipe", "ignore", "pipe"] })
      let stderr = ""
      child.stderr.setEncoding("utf8")
      child.stderr.on("data", (chunk: string) => {
        if (stderr.length < 16_384) stderr += chunk
      })
      child.once("error", reject)
      child.once("exit", (code) => {
        if (code === 0) resolve()
        else reject(new Error(stderr.trim() || `Authentication command exited with status ${code}`))
      })
      child.stdin.end(`${input}\n`)
    })

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
    const terminal = terminalLogins.get(flowId)
    if (terminal !== undefined) {
      await run(config.terminal.closeTerminal(terminal.terminalId))
      terminalLogins.delete(flowId)
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
      await execFileAsync(command, ["auth", "logout"], {
        env: await accountEnv(account),
        timeout: 30_000
      })
    } else {
      await run(config.agents.logoutHarness(account.harnessId, await contextFor(account)))
    }
    return probeAccount(accountId, true)
  }

  return {
    decorateHarnesses,
    refresh,
    accounts: async (harnessId) =>
      (await run(config.db.listHarnessAccounts(harnessId))).map(publicAccount),
    createAccount,
    renameAccount,
    removeAccount,
    activateAccount,
    probeAccount,
    beginLogin,
    cancelLogin,
    logout,
    accountContext: async (accountId) => {
      const state = await probeAccount(accountId)
      if (state.authState !== "authenticated" && state.authState !== "notRequired") {
        throw new Error("Harness account requires sign-in")
      }
      const account = await run(config.db.getHarnessAccount(accountId))
      if (account === undefined) throw new Error(`Harness account not found: ${accountId}`)
      return contextFor(account)
    },
    activeAccountContext: async (harnessId) => {
      const accounts = await run(config.db.listHarnessAccounts(harnessId))
      const account = accounts.find((candidate) => candidate.isActive) ?? accounts[0]
      if (account === undefined) return undefined
      const state = await probeAccount(account.id)
      return state.authState === "authenticated" || state.authState === "notRequired"
        ? contextFor(account)
        : undefined
    },
    markAccountExpired: async (accountId, detail) => {
      const account = await run(config.db.getHarnessAccount(accountId))
      if (account === undefined) return
      await persistProbe(account, {
        authState: "expired",
        canLogin: true,
        canLogout: account.canLogout,
        detail: detail ?? "Sign-in expired. Sign in again to continue."
      })
    },
    subscribe: (listener) => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    }
  }
}
