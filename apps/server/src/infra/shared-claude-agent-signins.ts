import { randomUUID } from "node:crypto"

import type { OpenCodeAuthFlow } from "@codevisor/api"
import type { HarnessAuthManager } from "@codevisor/harness-manager"

export type ClaudeSignInAuth = Pick<
  HarnessAuthManager,
  "beginLogin" | "answerLogin" | "cancelLogin" | "removeAccount"
>

export interface ClaudePlaceholders {
  readonly create: () => Promise<string>
  readonly discard: (placeholderId: string) => Promise<unknown>
}

export interface ClaudeSignInTarget {
  readonly accountId: string
  readonly providerId: string
}

export type ClaudeSignInFinish = (claudeAccountId: string) => Promise<void>

export const CLAUDE_HARNESS = "claude-code"
export const CLAUDE_HARNESS_NAME = "Claude Code"

const CODE_INSTRUCTIONS = "Sign in to Claude in your browser, then paste the code it shows."
const NO_CODE_MESSAGE =
  "This Claude sign-in can't finish here. Add the account in Claude settings, then choose it."

interface Attempt {
  readonly placeholder: string
  readonly login?: string
}

interface SignIn {
  value: OpenCodeAuthFlow
  readonly attempt: Attempt
  readonly claudeFlowId: string
  readonly finish: ClaudeSignInFinish
}

export const makeClaudeSignIns = (deps: {
  readonly auth: ClaudeSignInAuth
  readonly placeholders: ClaudePlaceholders
  readonly resolve: (claudeAccountId: string) => Promise<string>
}) => {
  const { auth, placeholders } = deps
  const signIns = new Map<string, SignIn>()

  const discard = async (attempt: Attempt) => {
    await placeholders.discard(attempt.placeholder).catch(() => undefined)
    if (attempt.login === undefined || attempt.login === attempt.placeholder) return
    await auth.removeAccount(attempt.login).catch(() => undefined)
  }

  const startLogin = async (placeholder: string) => {
    let flow: Awaited<ReturnType<ClaudeSignInAuth["beginLogin"]>>
    try {
      flow = await auth.beginLogin(placeholder)
    } catch (cause) {
      await discard({ placeholder })
      throw cause
    }
    if (flow.kind === "pasteCode") return flow

    await auth.cancelLogin(flow.id)
    await discard({ placeholder, login: flow.accountId })
    throw new Error(NO_CODE_MESSAGE)
  }

  const complete = async (signIn: SignIn, code: string): Promise<OpenCodeAuthFlow> => {
    try {
      await auth.answerLogin(signIn.claudeFlowId, code)
    } catch (cause) {
      await discard(signIn.attempt)
      return failed(signIn.value, cause)
    }
    try {
      await signIn.finish(await deps.resolve(signIn.attempt.placeholder))
    } catch (cause) {
      return failed(signIn.value, cause)
    }
    return { ...signIn.value, state: "complete" }
  }

  return {
    begin: async (
      target: ClaudeSignInTarget,
      finish: ClaudeSignInFinish
    ): Promise<OpenCodeAuthFlow> => {
      forgetEnded(signIns)
      const placeholder = await placeholders.create()
      const started = await startLogin(placeholder)
      const value = waitingFlow(target, started.url)
      const attempt = { placeholder, login: started.accountId }
      signIns.set(value.id, { value, attempt, claudeFlowId: started.id, finish })
      return value
    },
    flow: (flowId: string): OpenCodeAuthFlow | undefined => signIns.get(flowId)?.value,
    answer: async (flowId: string, code: string): Promise<OpenCodeAuthFlow | undefined> => {
      const signIn = signIns.get(flowId)
      if (signIn === undefined || signIn.value.state === "complete") return signIn?.value

      signIn.value = await complete(signIn, code)
      return signIn.value
    },
    cancel: async (flowId: string): Promise<void> => {
      const signIn = signIns.get(flowId)
      if (signIn === undefined) return

      signIns.delete(flowId)
      if (signIn.value.state !== "waiting") return
      await auth.cancelLogin(signIn.claudeFlowId)
      await discard(signIn.attempt)
    }
  }
}

export type ClaudeSignIns = ReturnType<typeof makeClaudeSignIns>

const waitingFlow = (target: ClaudeSignInTarget, url: string): OpenCodeAuthFlow => ({
  id: randomUUID(),
  ...target,
  state: "waiting",
  authorization: { url, method: "code", instructions: CODE_INSTRUCTIONS },
  harnessName: CLAUDE_HARNESS_NAME
})

const failed = (flow: OpenCodeAuthFlow, cause: unknown): OpenCodeAuthFlow => ({
  ...flow,
  state: "error",
  error: cause instanceof Error ? cause.message : String(cause)
})

const forgetEnded = (signIns: Map<string, SignIn>) => {
  for (const [id, signIn] of signIns) if (signIn.value.state !== "waiting") signIns.delete(id)
}
