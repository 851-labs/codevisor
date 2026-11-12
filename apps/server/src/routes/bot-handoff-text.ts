import type { BotMessage } from "@codevisor/api"

export interface BotHandoff {
  readonly sourceName: string
  readonly sourceHarness: string
  readonly targetHarness: string
  readonly messages: ReadonlyArray<BotMessage>
  readonly agents: ReadonlyArray<HandoffAgent>
}

export interface HandoffAgent {
  readonly id: string
  readonly title: string
  readonly isWorking: boolean
}

export const HANDOFF_OPENING = '<codevisor-event type="bot.handoff">'
export const HANDOFF_CLOSING = "</codevisor-event>"
export const HANDOFF_MESSAGE_LIMIT = 40

export const handoffText = (handoff: BotHandoff): string =>
  [
    HANDOFF_OPENING,
    introduction(handoff),
    ...conversationSection(handoff.messages),
    ...agentsSection(handoff.agents),
    HANDOFF_CLOSING
  ].join("\n\n")

const maxMessageCharacters = 2_000
const maxConversationCharacters = 16_000

const introduction = (handoff: BotHandoff): string =>
  [
    `You're a fork of the bot ${handoff.sourceName}, which ran on ${handoff.sourceHarness}.`,
    `You now run on ${handoff.targetHarness}.`,
    "Your AGENTS.md, including your Notes, and your messages with the user carried over,",
    "so `messages.list` shows them. Pick up where the conversation left off without",
    "announcing the switch, and handle what follows this event."
  ].join(" ")

const conversationSection = (messages: ReadonlyArray<BotMessage>): ReadonlyArray<string> => {
  const recent = withinBudget(messages.map(messageLine))
  if (recent.length === 0) return []

  return ["## Recent conversation", recent.join("\n")]
}

const withinBudget = (lines: ReadonlyArray<string>): ReadonlyArray<string> => {
  const kept: Array<string> = []
  let characters = 0
  for (const line of lines.toReversed()) {
    characters += line.length
    if (characters > maxConversationCharacters) break
    kept.unshift(line)
  }
  return kept
}

const messageLine = (message: BotMessage): string =>
  `[${message.sender} ${message.createdAt}] ${clipped(message.text)}${attachmentNote(message)}`

const clipped = (text: string): string => {
  const trimmed = text.trim()
  if (trimmed.length <= maxMessageCharacters) return trimmed
  return `${trimmed.slice(0, maxMessageCharacters)}…`
}

const attachmentNote = (message: BotMessage): string => {
  const names = (message.attachments ?? []).map((attachment) => attachment.name)
  if (names.length === 0) return ""
  return ` (attached: ${names.join(", ")})`
}

const agentsSection = (agents: ReadonlyArray<HandoffAgent>): ReadonlyArray<string> => {
  if (agents.length === 0) return []

  return [
    "## Your agents",
    "These agents moved to you, so their results now come to you.",
    agents.map(agentLine).join("\n")
  ]
}

const agentLine = (agent: HandoffAgent): string =>
  `- ${agent.title} (agentId \`${agent.id}\`): ${agent.isWorking ? "working" : "idle"}`
