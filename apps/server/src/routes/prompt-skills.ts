import type { SessionSkills } from "@codevisor/api"

import { run, type CodevisorServerServices } from "../server-context.js"

const SKILL_TOKEN = /(^|\s)[/$]([\w.:-]+)/g

/// Rewrites a prompt that invokes Codevisor skills (Codevisor's guides and
/// the user's saved skills) for the harness. Harnesses can't see those skills
/// (agents read them through the tool gateway's `skills` tool), and Claude
/// would reject a leading `/name` as an unknown command. Each `/name` or
/// `$name` token for a Codevisor skill the harness has no skill of its own for
/// becomes plain text, and a note asks the agent to load the skills first.
/// The transcript keeps what the user typed.
export const expandCodevisorSkills = (
  text: string,
  codevisorSkills: ReadonlyArray<string>,
  nativeSkills: SessionSkills | undefined
): string => {
  const native = new Set(nativeSkills?.skills.map((skill) => skill.name))
  const store = new Set(codevisorSkills.filter((name) => !native.has(name)))
  if (store.size === 0) return text
  const invoked: Array<string> = []
  const rewritten = text.replaceAll(SKILL_TOKEN, (token, lead: string, name: string) => {
    // Trailing punctuation ends a sentence, not the name.
    const bare = store.has(name) ? name : name.replace(/[.:-]+$/, "")
    if (!store.has(bare)) return token
    if (!invoked.includes(bare)) invoked.push(bare)
    return `${lead}\`${bare}\`${name.slice(bare.length)}`
  })
  if (invoked.length === 0) return text
  const names = invoked.map((name) => `\`${name}\``).join(", ")
  const one = invoked.length === 1
  const note = `The user invoked ${one ? "the Codevisor skill" : "these Codevisor skills"} ${names}. Before anything else, read ${one ? "it" : "each one"} with the Codevisor \`skills\` tool (pass the skill's name) and follow ${one ? "its" : "their"} instructions for this request.`
  return `${rewritten}\n\n<codevisor-skills>\n${note}\n</codevisor-skills>`
}

/// The prompt as the harness should see it when it invokes Codevisor
/// skills, which only the tool gateway can serve.
export const withCodevisorSkills = async (
  services: CodevisorServerServices,
  sessionId: string,
  text: string,
  nativeSkills: SessionSkills | undefined
): Promise<string> => {
  if (services.mcp === undefined) return text
  try {
    const session = await run(services.db.getSessionSummary(sessionId))
    const offered = await services.mcp.composerSkills(session.projectId, sessionId)
    return expandCodevisorSkills(
      text,
      offered.map((skill) => skill.name),
      nativeSkills ?? (await run(services.db.getSessionSkills(sessionId)))
    )
  } catch {
    // The skill list is best-effort context; the prompt itself must still run.
    return text
  }
}
