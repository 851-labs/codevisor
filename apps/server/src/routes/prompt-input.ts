import { isCompactPrompt, type PromptInput } from "@codevisor/agent-runtime"
import type { PromptQueueItem } from "@codevisor/api"

import { resolvePromptAttachments, type CodevisorServerServices } from "../server-context.js"
import { withConversationRecap } from "./conversation-recap.js"
import { withAppContexts, type AppContextPrompt } from "./prompt-app-context.js"
import { withCodevisorSkills } from "./prompt-skills.js"

export interface ResolvedPromptInput {
  readonly input: string | PromptInput
  readonly delivered: AppContextPrompt["delivered"]
}

export const promptInput = async (
  services: CodevisorServerServices,
  sessionId: string,
  item: Pick<PromptQueueItem, "text" | "attachments" | "origin">,
  skills: Parameters<typeof withCodevisorSkills>[3]
): Promise<ResolvedPromptInput> => {
  const refs = item.attachments ?? []
  const prompt = await promptText(services, sessionId, item, skills)
  if (refs.length === 0) return { input: prompt.text, delivered: prompt.delivered }
  const attachments = await resolvePromptAttachments(services, refs)
  return { input: { attachments, text: prompt.text }, delivered: prompt.delivered }
}

const promptText = async (
  services: CodevisorServerServices,
  sessionId: string,
  item: Pick<PromptQueueItem, "text" | "origin">,
  skills: Parameters<typeof withCodevisorSkills>[3]
): Promise<AppContextPrompt> => {
  if (isCompactPrompt(item.text)) return { text: item.text, delivered: [] }

  const text = withConversationRecap(services, sessionId, item.text)
  if (item.origin === "system") return { text, delivered: [] }
  const typed = await withCodevisorSkills(services, sessionId, text, skills)
  return withAppContexts(services, sessionId, typed)
}
