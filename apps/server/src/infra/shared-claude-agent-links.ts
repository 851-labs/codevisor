import { stringField } from "../unknown-values.js"
import type { SharedAccountStore } from "./shared-account-store.js"

export const CLAUDE_AGENT_LINK_PREFIX = "claude-agent:"

export interface ClaudeAgentLinks {
  readonly get: (profile: string) => Promise<string | undefined>
  readonly set: (profile: string, accountId: string) => Promise<void>
  readonly remove: (profile: string) => Promise<boolean>
}

export const makeClaudeAgentLinks = (
  store: Pick<SharedAccountStore, "entries" | "writeProvider">
): ClaudeAgentLinks => {
  const get = async (profile: string) => {
    const entry = (await store.entries()).find(
      (candidate) => candidate.key === linkKey(profile) && candidate.deleted !== true
    )
    return stringField(entry?.value, "accountId")
  }
  return {
    get,
    set: (profile, accountId) => store.writeProvider(linkKey(profile), { accountId }),
    remove: async (profile) => {
      if ((await get(profile)) === undefined) return false

      await store.writeProvider(linkKey(profile), null, true)
      return true
    }
  }
}

const linkKey = (profile: string) => `${CLAUDE_AGENT_LINK_PREFIX}${profile}`
