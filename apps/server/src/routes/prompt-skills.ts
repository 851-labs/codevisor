import type { SessionSkills } from "@codevisor/api"

import { run, type CodevisorServerServices } from "../server-context.js"

const SKILL_TOKEN = /(^|\s)[/$]([\w.:-]+)/g

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
    return text
  }
}
