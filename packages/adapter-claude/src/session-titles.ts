import type { SDKSessionInfo } from "@anthropic-ai/claude-agent-sdk"

import { startsWithInterruptedStepNote } from "./step-interrupts.js"

type TitledSession = Pick<SDKSessionInfo, "customTitle" | "summary">

export const claudeSessionTitle = (session: TitledSession | undefined): string | undefined => {
  const title = (session?.customTitle ?? session?.summary)?.trim()
  if (title === undefined || title.length === 0) return undefined
  if (startsWithInterruptedStepNote(title)) return undefined

  return title
}
