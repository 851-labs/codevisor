import {
  makeOpenCodeLocator,
  makeOpenCodeVersionProbe,
  pendingOpenCodeMigration,
  startOpenCodeServer,
  type OpenCodeMigration
} from "@codevisor/adapter-opencode"
import type { HarnessAccountContext } from "@codevisor/agent-runtime"
import type { HarnessAuthManager, PendingHarnessSetup } from "@codevisor/harness-manager"

export interface OpenCodeSetupDeps {
  readonly accounts?: () => Promise<ReadonlyArray<HarnessAccountContext>>
  readonly locate?: (env: NodeJS.ProcessEnv) => string | undefined
  readonly majorVersion?: (command: string) => Promise<number | undefined>
  readonly migration?: (
    command: string,
    env: NodeJS.ProcessEnv
  ) => Promise<OpenCodeMigration | undefined>
}

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

const chatEnv = (env: NodeJS.ProcessEnv, context: HarnessAccountContext): NodeJS.ProcessEnv => {
  const inherited = { ...env }
  for (const name of context.unsetEnv ?? []) delete inherited[name]
  return { ...inherited, ...context.env }
}

const dataLocation = (env: NodeJS.ProcessEnv) =>
  JSON.stringify([env.OPENCODE_DB, env.XDG_DATA_HOME, env.HOME])

/* v8 ignore start */
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
