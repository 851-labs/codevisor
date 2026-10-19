import { readFile } from "node:fs/promises"

import type { ComposerSkill } from "@codevisor/api"
import { codevisorSandboxSignatures } from "@codevisor/automation"
import { parseFrontmatter, RESERVED_SKILL_NAMES } from "@codevisor/skills"
import type { Tool } from "@modelcontextprotocol/sdk/types.js"

export interface SkillSource {
  readonly list: () => Promise<{
    readonly skills: ReadonlyArray<{
      readonly directoryName: string
      readonly name: string
      readonly description?: string | undefined
    }>
  }>
  readonly document: (directoryName: string) => Promise<
    | {
        readonly content: string
        readonly path: string
        readonly files: ReadonlyArray<string>
      }
    | undefined
  >
  readonly subscribe: (listener: () => void) => () => void
}

export interface PackagedSkill {
  readonly name: string
  readonly summary: string
  readonly path: string
  readonly composer?: string
}

export interface SkillContext {
  readonly enabledIds: ReadonlySet<string>
  readonly pluginTools: ReadonlyArray<Tool>
}

export interface BuiltinSkill {
  readonly name: string
  readonly summary: string
  readonly composer?: string
  readonly gate?: string
  readonly load: (context: SkillContext) => Promise<string>
}

export interface SkillEntry {
  readonly name: string
  readonly summary: string
  readonly builtin: boolean
  readonly composer?: string
  readonly read: () => Promise<string | undefined>
}

export const DESCRIPTION_GUIDANCE = [
  "`description` is the label the user sees for this run. Write a short, plain-text, present-tense phrase that starts with a verb and names what the code does (at most 80 characters; longer labels are cut).",
  'Good: "Find open Linear issues assigned to me", "Build the macOS app on MacBook", "Create an agent for each failing test".',
  'Bad: "Running code" (says nothing), "I\'ll search Linear for your issues" (not a verb-first label), "`linear.list_issues` + filter()" (code, not prose).'
].join("\n")

const stripFrontmatter = (raw: string): string => {
  try {
    return parseFrontmatter(raw).content.trim()
  } catch {
    return raw.trim()
  }
}

export const packagedSkill = (
  skill: {
    readonly name: string
    readonly summary: string
    readonly path: () => string
    readonly composer?: string | undefined
  },
  gate?: string
): BuiltinSkill => ({
  name: skill.name,
  summary: skill.summary,
  ...(skill.composer === undefined ? {} : { composer: skill.composer }),
  ...(gate === undefined ? {} : { gate }),
  load: async () => stripFrontmatter(await readFile(skill.path(), "utf8"))
})

const CAPABILITY_SKILLS: ReadonlyArray<{ readonly gate: string; readonly line: string }> = [
  { gate: "browser", line: "- Browser: read `browser-use`." },
  { gate: "computer", line: "- Desktop apps and screen recording: read `computer-use`." },
  {
    gate: "codevisor",
    line: "- Codevisor: read `codevisor`, then `codevisor-agents`, `codevisor-machines`, or `codevisor-clients`."
  },
  {
    gate: "bot",
    line: "- Talking to the user (you are a bot; they only see what you send): read `codevisor-messages`."
  }
]

export const executeSkill: BuiltinSkill = {
  name: "execute",
  summary: "how to write code for `execute`: tool discovery, labels, other agents, sandbox globals",
  load: async ({ enabledIds, pluginTools }) => {
    const sections = [
      "# execute",
      [
        "## How it works",
        'Pass an async arrow function of sandboxed JavaScript or TypeScript. It runs on this machine, or on the user\'s other machines through `machines`. The isolate itself has no filesystem, network, process environment, or credentials. Start with `await tools.search({ query: "<intent>" })`, inspect a match with `await tools.describe.tool({ path })`, then call the exact returned path with `await tools[path](args)`. Call `status("…")` before slow steps so the user sees progress.'
      ].join("\n\n"),
      ["## The `description` argument", DESCRIPTION_GUIDANCE].join("\n\n"),
      [
        "## The `timeout_ms` argument and background jobs",
        '`timeout_ms` (default 120000, maximum 600000) is how long the call waits for your code. Nothing is cancelled when it passes: the code keeps running as a background job, and the call returns `{ status: "running", jobId, running, progress, logs, outputPath, next }` instead of a result. Waits such as `codevisor.sessions.wait`, `codevisor.jobs.wait`, and Computer Use `waitFor` shorten themselves to fit the budget that is left and return `timedOut`, so your code can still return what it has.',
        "When you get a job handle, prefer ending your turn: Codevisor sends you a hidden `<codevisor-event type=\"execution.job_finished\">` message with the job's result when it finishes, even if your harness would not otherwise wake up. To check sooner, call execute with `tools.codevisor.jobs.wait({ jobId })` (waits within that call's budget) or `tools.codevisor.jobs.get({ jobId })`; reading a finished result that way means no event is sent. `tools.codevisor.jobs.cancel({ jobId })` stops a job, and `tools.codevisor.jobs.list()` shows this session's jobs. `outputPath` is a log file with live `status()` text, console output, tool calls, and the final result. Jobs stop after 30 minutes and don't survive a server restart."
      ].join("\n\n"),
      [
        "## Skills for each capability",
        "Read the skill for a capability (call the `skills` tool with its name) before using it.",
        [
          ...CAPABILITY_SKILLS.filter((skill) => enabledIds.has(skill.gate)).map(
            (skill) => skill.line
          ),
          "- Sending files, screenshots, or recordings to the user: read `attaching-files`."
        ].join("\n")
      ].join("\n\n")
    ]
    if (enabledIds.has("codevisor")) {
      sections.push(
        [
          "## Other agents",
          "Built-in subagents usually fit help with your current task; a Codevisor chat in the current workspace fits another harness or model working on the same change; a new Codevisor workspace with its own worktree fits separate work that ends in its own branch or PR. Read `codevisor-agents` before starting one."
        ].join("\n\n")
      )
    }
    if (pluginTools.length > 0) {
      sections.push(
        [
          '## Installed plugin tools (call through server "plugin")',
          pluginTools.map((tool) => `- plugin.${tool.name} — ${tool.description}`).join("\n")
        ].join("\n\n")
      )
    }
    sections.push(`## Sandbox globals\n\n\`\`\`ts\n${codevisorSandboxSignatures}\n\`\`\``)
    return sections.join("\n\n")
  }
}

export const skillEntries = async (
  builtins: ReadonlyArray<BuiltinSkill>,
  context: SkillContext,
  source: SkillSource | undefined
): Promise<ReadonlyArray<SkillEntry>> => {
  const visible = builtins.filter(
    (skill) => skill.gate === undefined || context.enabledIds.has(skill.gate)
  )
  const saved =
    source === undefined
      ? []
      : (await source.list()).skills
          .filter((skill) => !RESERVED_SKILL_NAMES.has(skill.directoryName))
          .map((skill) => ({
            builtin: false,
            name: skill.directoryName,
            read: async () => {
              const document = await source.document(skill.directoryName)
              if (document === undefined) return undefined
              const body = stripFrontmatter(document.content)
              if (document.files.length === 0) return body
              return [
                body,
                `Skill folder: ${document.path}`,
                `Supporting files (relative to the skill folder; open them with your file tools): ${document.files.join(", ")}`
              ].join("\n\n")
            },
            summary: skill.description ?? skill.name,
            ...(skill.description === undefined ? {} : { composer: skill.description })
          }))
  return [
    ...visible.map((skill) => ({
      builtin: true,
      name: skill.name,
      read: () => skill.load(context),
      summary: skill.summary,
      ...(skill.composer === undefined ? {} : { composer: skill.composer })
    })),
    ...saved
  ]
}

export const composerSkills = (entries: ReadonlyArray<SkillEntry>): ReadonlyArray<ComposerSkill> =>
  entries.flatMap((entry): ReadonlyArray<ComposerSkill> => {
    if (entry.builtin && entry.composer === undefined) return []
    return [
      {
        builtin: entry.builtin,
        name: entry.name,
        ...(entry.composer === undefined ? {} : { description: entry.composer })
      }
    ]
  })

const DESCRIPTION_BUDGET = 1_900
const SUMMARY_LIMIT = 100

const summaryLine = (entry: SkillEntry): string => {
  const summary = entry.summary.replaceAll(/\s+/g, " ").trim()
  return `- ${entry.name} — ${
    summary.length > SUMMARY_LIMIT ? `${summary.slice(0, SUMMARY_LIMIT - 1)}…` : summary
  }`
}

export const skillsToolDescription = (entries: ReadonlyArray<SkillEntry>): string => {
  const lines = [
    "How-to guides for the `execute` tool, plus the user's saved skills. Before using a capability, call this tool with that skill's name and follow it. Call it with no name to list every skill.",
    "",
    ...entries.filter((entry) => entry.builtin).map(summaryLine)
  ]
  const saved = entries.filter((entry) => !entry.builtin)
  if (saved.length === 0) return lines.join("\n")
  lines.push("", "The user's skills:")
  let length = lines.join("\n").length
  for (const [index, entry] of saved.entries()) {
    const line = summaryLine(entry)
    const remaining = saved.length - index
    const more = `- …and ${remaining} more (call with no name)`
    const reserve = remaining > 1 ? more.length + 1 : 0
    if (length + line.length + 1 + reserve > DESCRIPTION_BUDGET) {
      lines.push(more)
      break
    }
    lines.push(line)
    length += line.length + 1
  }
  return lines.join("\n")
}

export const skillsToolResult = async (
  entries: ReadonlyArray<SkillEntry>,
  name: string | undefined
): Promise<{ readonly text: string; readonly isError: boolean }> => {
  const index = entries.map((entry) => `- ${entry.name} — ${entry.summary}`).join("\n")
  if (name === undefined || name.trim() === "") {
    return { isError: false, text: `Skills (call this tool with a name to read one):\n${index}` }
  }
  const wanted = name.trim()
  const entry = entries.find((candidate) => candidate.name === wanted)
  const text = entry === undefined ? undefined : await entry.read()
  if (text === undefined) {
    return { isError: true, text: `No skill named "${wanted}". Available skills:\n${index}` }
  }
  return { isError: false, text }
}
