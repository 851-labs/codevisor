import {
  makeOpenCodeLocator,
  makeOpenCodeVersionProbe,
  pendingOpenCodeMigration,
  startOpenCodeServer,
  type OpenCodeMigration
} from "@codevisor/adapter-opencode"
import type { HarnessAccountContext } from "@codevisor/agent-runtime"
import type { HarnessAuthManager, PendingHarnessSetup } from "@codevisor/harness-manager"

/// OpenCode 2 moves OpenCode 1's sessions into its own format, and fails
/// requests until it's done. Codevisor sees that through, on the data each
/// OpenCode account's chats use, before chats use OpenCode.

export interface OpenCodeSetupDeps {
  /// Each OpenCode account's chat environment, over the user's own.
  readonly accounts?: () => Promise<ReadonlyArray<HarnessAccountContext>>
  readonly locate?: (env: NodeJS.ProcessEnv) => string | undefined
  readonly majorVersion?: (command: string) => Promise<number | undefined>
  readonly migration?: (
    command: string,
    env: NodeJS.ProcessEnv
  ) => Promise<OpenCodeMigration | undefined>
}

/// The OpenCode accounts' chat environments, skipping any that can't be
/// prepared: their chats report that themselves.
export const openCodeAccountContexts =
  (auth: Pick<HarnessAuthManager, "accounts" | "accountContext">) =>
  async (): Promise<ReadonlyArray<HarnessAccountContext>> => {
    const contexts = await Promise.all(
      (await auth.accounts("opencode")).map((account) =>
        auth.accountContext(account.id).catch(() => undefined)
      )
    )
    return contexts.filter((context) => context !== undefined)
  }

/// The environment a chat on `context` runs OpenCode with.
const chatEnv = (env: NodeJS.ProcessEnv, context: HarnessAccountContext): NodeJS.ProcessEnv => {
  const inherited = { ...env }
  for (const name of context.unsetEnv ?? []) delete inherited[name]
  return { ...inherited, ...context.env }
}

/// Where OpenCode keeps its data in an environment; accounts sharing data
/// migrate it once.
const dataLocation = (env: NodeJS.ProcessEnv) =>
  JSON.stringify([env.OPENCODE_DB, env.XDG_DATA_HOME, env.HOME])

/* v8 ignore start -- starts a real OpenCode server; tests inject the migration. */
const migrateWithServer = (command: string, env: NodeJS.ProcessEnv) =>
  pendingOpenCodeMigration({
    start: () =>
      startOpenCodeServer({ command, env, ...(env.HOME === undefined ? {} : { cwd: env.HOME }) })
  })
/* v8 ignore stop */

export const makeOpenCodeSetup = (deps: OpenCodeSetupDeps = {}) => {
  const locate = deps.locate ?? makeOpenCodeLocator()
  const majorVersion = deps.majorVersion ?? makeOpenCodeVersionProbe()
  const migration = deps.migration ?? migrateWithServer
  return async (env: NodeJS.ProcessEnv): Promise<PendingHarnessSetup | undefined> => {
    const command = locate(env)
    if (command === undefined || ((await majorVersion(command)) ?? 1) < 2) return undefined
    const accounts = (await deps.accounts?.().catch(() => undefined)) ?? []
    const envs = new Map(
      (accounts.length === 0 ? [env] : accounts.map((context) => chatEnv(env, context))).map(
        (chat) => [dataLocation(chat), chat]
      )
    )
    const checks = await Promise.allSettled(
      [...envs.values()].map((chat) => migration(command, chat))
    )
    // OpenCode that can't start anywhere is the install's failure; a single
    // account that can't is left for its chats to report.
    const failed = checks.find((check) => check.status === "rejected")
    if (checks.every((check) => check.status === "rejected")) throw failed!.reason
    const pending = checks.flatMap((check) =>
      check.status === "fulfilled" && check.value !== undefined ? [check.value] : []
    )
    if (pending.length === 0) return undefined
    return {
      finish: async () => {
        await Promise.all(pending.map((entry) => entry.finish()))
      }
    }
  }
}
