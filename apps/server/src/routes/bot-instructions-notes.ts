import { BLOCK_BEGIN, BLOCK_END, NOTES_HEADING } from "./bot-instructions-text.js"

export const notesOutsideBlock = (text: string, generatedBlock: string): ReadonlyArray<string> => {
  const generated = generatedText(generatedBlock)
  return paragraphs(text).flatMap((part, index) => keptPart(part, index, generated))
}

interface GeneratedText {
  readonly paragraphs: ReadonlySet<string>
  readonly lines: ReadonlySet<string>
}

const generatedText = (block: string): GeneratedText => {
  const parts = [...legacyParagraphs, ...paragraphs(block)].map(normalized)
  const lines = parts.flatMap((part) => part.split("\n")).map(normalized)
  return { paragraphs: new Set(parts), lines: new Set([...lines, BLOCK_BEGIN, BLOCK_END]) }
}

const keptPart = (part: string, index: number, generated: GeneratedText): ReadonlyArray<string> => {
  if (index === 0 && isTitle(part)) return []
  if (generated.paragraphs.has(normalized(part))) return []
  if (!isList(part)) return [part]

  const kept = part.split("\n").filter((line) => !isGeneratedLine(line, generated))
  return kept.length === 0 ? [] : [kept.join("\n")]
}

const paragraphs = (text: string): ReadonlyArray<string> =>
  text
    .split(/\n[ \t]*\n/)
    .map((part) => part.trim())
    .filter((part) => part.length > 0)

const normalized = (text: string): string =>
  text
    .split("\n")
    .map((line) => line.trim().replaceAll(/\s+/g, " "))
    .join(isList(text) ? "\n" : " ")

const isTitle = (part: string): boolean => /^# [^\n]+$/.test(part)

const isList = (part: string): boolean =>
  part.split("\n").every((line) => /^\s*(?:-|\d+\.) /.test(line) || isMarker(line))

const isMarker = (line: string): boolean => line.trim() === BLOCK_BEGIN || line.trim() === BLOCK_END

const isGeneratedLine = (line: string, generated: GeneratedText): boolean => {
  const trimmed = normalized(line)
  return generated.lines.has(trimmed) || legacyLines.some((pattern) => pattern.test(trimmed))
}

const legacyParagraphs: ReadonlyArray<string> = [
  "## Talking to the user",
  "## Repositories",
  "## Delegating work",
  NOTES_HEADING,
  BLOCK_BEGIN,
  BLOCK_END,
  "You are a long-lived Codevisor bot that coordinates work across the repositories below. Plan the work, hand it to sub-agents, and follow up on their results. Don't change code yourself; read the folders below to understand the code and decide what to delegate.",
  "The user chats with you like iMessage and only sees the messages you send with `codevisor.messages.send` through the Codevisor MCP. Nothing else you write reaches them, not even your final reply. Read the `codevisor-messages` skill before your first reply.",
  "The user chats with you like iMessage and only sees the messages you send with `machines.current.tools.codevisor.messages.send` through the Codevisor MCP. Nothing else you write reaches them, not even your final reply. Read the `codevisor-messages` skill before your first reply.",
  "When a task needs a repository that isn't listed, add it with `bot.projects_add({ projectId })`, using a projectId from `projects.list`. Remove one you no longer need with `bot.projects_remove({ projectId })`.",
  "When a task needs a repository that isn't listed, add it with `machines.current.tools.codevisor.bot.projects_add({ projectId })`, using a projectId from `projects.list`. Remove one you no longer need with `bot.projects_remove({ projectId })`.",
  "Give each task to a sub-agent in a workspace of its own with the Codevisor MCP, on an isolated worktree of the repository it changes. Use the projectId above; this folder is not a project you can branch from.",
  "Give each task to a sub-agent in a workspace of its own with the Codevisor MCP's execute tool, on an isolated worktree of the repository it changes. Use the projectId above; this folder is not a project you can branch from.",
  "Workspaces your sub-agents work in, and any they create, are listed under this bot in the Codevisor sidebar."
]

const legacyLines: ReadonlyArray<RegExp> = [
  /^- `[^`]+\/`: .+ \(from `[^`]+`, projectId `[^`]+`\)$/,
  /^1\. `worktrees\.create\(\{ projectId \}\)`$/,
  /^2\. `sessions\.create\(\{ projectId, worktreeName,(?: harnessId: "[^"]*",)? title \}\)`$/,
  /^3\. `sessions\.prompt\(\{ sessionId, text \}\)`$/,
  /^4\. `sessions\.wait` or `sessions\.get` to follow up$/,
  /^4\. End your turn\. When the agent finishes, Codevisor sends you a `<codevisor-event>` with its result$/,
  /^1\. `machines\.current\.agents\.start\(\{ project: projectId, isolation: "worktree", title, prompt \}\)`$/,
  /^2\. `machines\.current\.agents\.status\(\{ agentId \}\)` or `machines\.current\.agents\.wait\(\{ agentIds \}\)` to follow up$/,
  /^2\. End your turn\. When the agent finishes, Codevisor sends you a `<codevisor-event>` with its complete final reply$/
]
