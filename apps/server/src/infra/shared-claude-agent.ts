import { randomUUID } from "node:crypto"

import {
  CLAUDE_AGENT_ACCOUNT_PROMPT,
  CLAUDE_AGENT_METHOD,
  CLAUDE_AGENT_PROVIDER,
  type ClaudeAgentLaunch
} from "@codevisor/adapter-opencode"
import { locateExecutableOnPath } from "@codevisor/agent-runtime"
import type {
  HarnessAccount,
  OpenCodeAuthFlow,
  OpenCodeAuthMethod,
  OpenCodeAuthPrompt,
  OpenCodeAuthProvider
} from "@codevisor/api"
import type { ClaudeAgentIntegration, HarnessAuthManager } from "@codevisor/harness-manager"

import type { ClaudeAgentLinks } from "./shared-claude-agent-links.js"
import { CLAUDE_HARNESS, type ClaudeSignIns } from "./shared-claude-agent-signins.js"

export interface SharedClaudeAgent extends ClaudeAgentIntegration {
  readonly linked: (profile: string) => Promise<boolean>
  readonly unlink: (profile: string) => Promise<boolean>
  readonly launch: (profile: string) => Promise<ClaudeAgentLaunch | undefined>
}

export interface SharedClaudeAgentDeps {
  readonly links: ClaudeAgentLinks
  readonly signIns: ClaudeSignIns
  readonly auth: Pick<HarnessAuthManager, "accounts" | "accountContext">
  readonly profile: (openCodeAccountId: string) => Promise<string>
  readonly environment: () => Promise<NodeJS.ProcessEnv>
  readonly locate?: (name: string, env: NodeJS.ProcessEnv) => string | undefined
}

export const NEW_CLAUDE_ACCOUNT = "new"

const UNAVAILABLE_LABEL = "Unavailable on this machine"

export const makeSharedClaudeAgent = (deps: SharedClaudeAgentDeps): SharedClaudeAgent => {
  const { links, signIns, auth } = deps
  const locate = deps.locate ?? locateExecutableOnPath

  const signedIn = async (shared = false) =>
    (await auth.accounts(CLAUDE_HARNESS, shared)).filter(isSignedIn)

  const requireSignedIn = async (claudeAccountId: string) => {
    if ((await signedIn()).some((account) => account.id === claudeAccountId)) return
    throw new Error("Sign in to this Claude account first.")
  }

  const claudeEnv = async (claudeAccountId: string) => {
    const context = await auth.accountContext(claudeAccountId).catch(() => undefined)
    return context === undefined ? undefined : (context.env ?? {})
  }

  return {
    provider: async (openCodeAccountId, listed, shared = false) => {
      const profile = await deps.profile(openCodeAccountId)
      const accounts = await signedIn(shared)
      const linkedId = await links.get(profile)
      return describe(listed, accounts, linkedId)
    },
    begin: async (openCodeAccountId, inputs) => {
      const profile = await deps.profile(openCodeAccountId)
      const target = { accountId: openCodeAccountId, providerId: CLAUDE_AGENT_PROVIDER }
      const chosen = inputs?.[CLAUDE_AGENT_ACCOUNT_PROMPT] ?? NEW_CLAUDE_ACCOUNT
      if (chosen === NEW_CLAUDE_ACCOUNT)
        return signIns.begin(target, (claudeAccountId) => links.set(profile, claudeAccountId))

      await requireSignedIn(chosen)
      await links.set(profile, chosen)
      return completed(target)
    },
    flow: signIns.flow,
    answer: signIns.answer,
    cancel: signIns.cancel,
    linked: async (profile) => (await links.get(profile)) !== undefined,
    unlink: links.remove,
    launch: async (profile) => {
      const claudeAccountId = await links.get(profile)
      if (claudeAccountId === undefined) return undefined

      const env = await claudeEnv(claudeAccountId)
      if (env === undefined) return undefined

      const claudePath = locate("claude", { ...(await deps.environment()), ...env })
      return claudePath === undefined ? undefined : { claudePath, env }
    }
  }
}

const isSignedIn = (account: HarnessAccount) =>
  account.authState === "authenticated" || account.authState === "notRequired"

const describe = (
  listed: OpenCodeAuthProvider,
  accounts: ReadonlyArray<HarnessAccount>,
  linkedId: string | undefined
): OpenCodeAuthProvider => {
  const method: OpenCodeAuthMethod = {
    id: CLAUDE_AGENT_METHOD,
    type: "oauth",
    label: "Claude account in Codevisor",
    prompts: [accountPrompt(accounts, linkedId)]
  }
  if (linkedId === undefined) return { ...listed, methods: [method] }

  const linked = accounts.find((account) => account.id === linkedId)
  return {
    ...listed,
    methods: [method],
    credentialType: "oauth",
    accountLabel: linked?.label ?? UNAVAILABLE_LABEL
  }
}

const accountPrompt = (
  accounts: ReadonlyArray<HarnessAccount>,
  linkedId: string | undefined
): OpenCodeAuthPrompt => {
  const defaultValue = accounts.some((account) => account.id === linkedId)
    ? linkedId
    : accounts[0]?.id
  return {
    type: "select",
    key: CLAUDE_AGENT_ACCOUNT_PROMPT,
    message: "Account",
    options: [
      ...accounts.map((account) => ({ value: account.id, label: account.label })),
      { value: NEW_CLAUDE_ACCOUNT, label: newAccountLabel(accounts) }
    ],
    required: true,
    defaultValue: defaultValue ?? NEW_CLAUDE_ACCOUNT
  }
}

const newAccountLabel = (accounts: ReadonlyArray<HarnessAccount>) =>
  accounts.length === 0 ? "Sign In to Claude…" : "Sign In to Another Account…"

const completed = (target: { accountId: string; providerId: string }): OpenCodeAuthFlow => ({
  id: randomUUID(),
  ...target,
  state: "complete"
})
