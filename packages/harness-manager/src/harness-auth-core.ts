import type { ChildProcess } from "node:child_process"
import { chmod, mkdir, readFile } from "node:fs/promises"
import { join } from "node:path"

import { spawnClaudeAuthClient, type ClaudeAuthClient } from "@codevisor/adapter-claude"
import type { spawnCodexClient } from "@codevisor/adapter-codex"
import {
  clampFailureDetail,
  harnessCatalog,
  locateExecutableOnPath,
  resolveShellEnv,
  type HarnessAccountContext,
  type HarnessDefinition
} from "@codevisor/agent-runtime"
import type { HarnessAccount, HarnessAuthMethod } from "@codevisor/api"
import type { HarnessAccountRecord, UpdateHarnessAccountAuthRequest } from "@codevisor/db"

import {
  defaultClaudeConfigPath,
  ensureSharedClaudeConversations
} from "./claude-conversation-storage.js"
import { CLAUDE_AUTH_OVERRIDE_ENV_VARS, defaultExecFile, run } from "./harness-auth-support.js"
import type {
  HarnessAuthEvent,
  HarnessAuthExec,
  HarnessAuthManagerConfig
} from "./harness-auth-types.js"

/// The account fields a probe can move that clients render. `lastCheckedAt`
/// is deliberately excluded: it changes on every probe.
const accountOutcomeChanged = (previous: HarnessAccount, next: HarnessAccount) =>
  previous.authState !== next.authState ||
  previous.authMethod !== next.authMethod ||
  (previous.detail ?? null) !== (next.detail ?? null) ||
  previous.canLogin !== next.canLogin ||
  previous.canLogout !== next.canLogout ||
  (previous.email ?? null) !== (next.email ?? null) ||
  (previous.organizationId ?? null) !== (next.organizationId ?? null)

export interface CodexLoginEntry {
  readonly accountId: string
  readonly client: Awaited<ReturnType<typeof spawnCodexClient>>
  readonly loginId?: string
}

/// The state and account-scoped helpers every auth module shares: the
/// listener fanout, in-flight probe/refresh/login registries, the login-shell
/// environment, and the managed-profile paths plus the env each account runs
/// its harness CLI with.
export const makeHarnessAuthCore = (config: HarnessAuthManagerConfig) => {
  /// Read lazily on every use: the runtime's catalog is a live view that
  /// changes when custom harnesses are added/removed at runtime.
  const catalogNow = (): ReadonlyArray<HarnessDefinition> =>
    config.catalog ?? config.agents.catalog ?? harnessCatalog
  const listeners = new Set<(event: HarnessAuthEvent) => void>()
  const probes = new Map<string, Promise<HarnessAccount>>()
  const refreshes = new Map<string, Promise<void>>()
  const codexLogins = new Map<string, CodexLoginEntry>()
  const claudeLogins = new Map<string, { accountId: string; client: ClaudeAuthClient }>()
  /// `cursor-agent login` stays resident while the user finishes in the
  /// browser and exits 0 once credentials are written, so the flow is the
  /// child process itself rather than a protocol client.
  const cursorLogins = new Map<string, { accountId: string; child: ChildProcess }>()
  const spawnClaudeAuth = config.claudeAuth ?? spawnClaudeAuthClient
  const acpLoginMethods = new Map<string, ReadonlyArray<HarnessAuthMethod>>()
  let environmentPromise: Promise<NodeJS.ProcessEnv> | undefined
  let claudeStoragePreparation: Promise<void> | undefined
  const runExecFile: HarnessAuthExec = config.execFile ?? defaultExecFile

  const emit = (event: HarnessAuthEvent): void => {
    for (const listener of listeners) listener(event)
  }

  const environment = (): Promise<NodeJS.ProcessEnv> => {
    environmentPromise ??= (config.resolveEnv?.() ?? resolveShellEnv()).finally(() => {
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
    const value = catalogNow().find((candidate) => candidate.id === harnessId)
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

  const prepareClaudeStorage = (): Promise<void> => {
    if (claudeStoragePreparation !== undefined) return claudeStoragePreparation
    const preparation = (async () => {
      const [baseEnvironment, accounts] = await Promise.all([
        environment(),
        run(config.db.listHarnessAccounts("claude-code"))
      ])
      await ensureSharedClaudeConversations(
        defaultClaudeConfigPath(baseEnvironment),
        accounts.flatMap((candidate) => {
          const candidatePath = profilePath(candidate)
          return candidatePath === undefined ? [] : [candidatePath]
        })
      )
    })()
    claudeStoragePreparation = preparation.finally(() => {
      claudeStoragePreparation = undefined
    })
    return claudeStoragePreparation
  }

  const contextFor = async (
    account: HarnessAccountRecord,
    shared = true
  ): Promise<HarnessAccountContext> => {
    const path = profilePath(account)
    if (path !== undefined) {
      await mkdir(path, { recursive: true, mode: 0o700 })
      await chmod(path, 0o700)
    }
    if (account.harnessId === "claude-code") await prepareClaudeStorage()
    const env: Record<string, string> = {}
    if (path !== undefined && account.harnessId === "codex") env.CODEX_HOME = path
    if (path !== undefined && account.harnessId === "claude-code") env.CLAUDE_CONFIG_DIR = path
    if (path !== undefined && account.harnessId === "opencode") {
      env.XDG_DATA_HOME = join(path, "data")
      env.XDG_CONFIG_HOME = join(path, "config")
      env.XDG_STATE_HOME = join(path, "state")
      env.XDG_CACHE_HOME = join(path, "cache")
    }
    const apiKey = await storedApiKey(account)
    if (apiKey !== undefined) {
      if (account.harnessId === "codex") env.OPENAI_API_KEY = apiKey
      if (account.harnessId === "claude-code") env.ANTHROPIC_API_KEY = apiKey
    }
    const context: HarnessAccountContext = {
      id: account.id,
      profileKind: account.profileKind,
      ...(path === undefined ? {} : { profilePath: path }),
      ...(Object.keys(env).length === 0 ? {} : { env })
    }
    return shared
      ? (config.sharedProviders?.()?.context(publicAccount(account), context) ?? context)
      : context
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
    const accountContext = await contextFor(account, false)
    if (account.profileKind === "managed" && account.harnessId === "claude-code") {
      for (const name of CLAUDE_AUTH_OVERRIDE_ENV_VARS) delete base[name]
    }
    if (account.profileKind === "managed" && account.harnessId === "opencode") {
      delete base.OPENCODE_AUTH_CONTENT
    }
    return { ...base, ...accountContext.env }
  }

  const accountCommand = async (
    account: HarnessAccountRecord
  ): Promise<{ readonly cwd: string; readonly env: NodeJS.ProcessEnv }> => {
    const env = await accountEnv(account)
    return {
      cwd: profilePath(account) ?? env.HOME ?? config.dataDir,
      env
    }
  }

  const persistProbe = async (
    account: HarnessAccountRecord,
    update: UpdateHarnessAccountAuthRequest
  ): Promise<HarnessAccount> => {
    // Single choke point for every probe path (codex, claude, ACP, and the
    // catch-all below). A crashing CLI's stderr must never reach the database
    // or the wire at full length — the UI renders this as a one-line subtitle.
    const clamped: UpdateHarnessAccountAuthRequest =
      typeof update.detail === "string"
        ? { ...update, detail: clampFailureDetail(update.detail) ?? null }
        : update
    const previous = await run(config.db.getHarnessAccount(account.id))
    const saved = await run(config.db.updateHarnessAccountAuth(account.id, clamped))
    return announce(previous, publicAccount(saved))
  }

  /// Publishes an account's settled state. Clients refetch the whole catalog
  /// on `harness.auth.updated`, and that refetch re-probes — so emit only when
  /// something they render changed; a probe that merely stamps
  /// `lastCheckedAt` must not start a loop.
  const announce = (previous: HarnessAccount | undefined, next: HarnessAccount) => {
    if (previous === undefined || accountOutcomeChanged(previous, next)) {
      emit({ kind: "harness.account.updated", subjectId: next.harnessId, payload: next })
      emit({ kind: "harness.auth.updated", subjectId: next.harnessId, payload: next })
    }
    return next
  }

  return {
    accountCommand,
    accountEnv,
    acpLoginMethods,
    announce,
    apiKeyPath,
    catalogNow,
    claudeLogins,
    codexLogins,
    cursorLogins,
    config,
    contextFor,
    definition,
    emit,
    environment,
    executable,
    listeners,
    persistProbe,
    prepareClaudeStorage,
    probes,
    profilePath,
    publicAccount,
    refreshes,
    runExecFile,
    spawnClaudeAuth
  }
}

export type HarnessAuthCore = ReturnType<typeof makeHarnessAuthCore>
