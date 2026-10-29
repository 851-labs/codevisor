import type { SessionSkill, SessionSkills } from "@codevisor/api"

import type { RuntimeEvent } from "./types.js"

export const SUPERSEDED_NATIVE_SKILLS: ReadonlyArray<string> = [
  "built-in-browser",
  "chrome-browser",
  "computer-use"
]

const superseded = (name: string): boolean =>
  SUPERSEDED_NATIVE_SKILLS.includes(name.slice(name.lastIndexOf(":") + 1))

export const SKILLS_UPDATE = "available_skills_update"

export const skillsUpdateEvent = (subjectId: string, skills: SessionSkills): RuntimeEvent => ({
  kind: "session.output",
  subjectId,
  payload: { sessionUpdate: SKILLS_UPDATE, ...skills }
})

export const sessionSkills = (
  skills: ReadonlyArray<SessionSkill>,
  invocationPrefix: string,
  commands: ReadonlyArray<string> = []
): SessionSkills => {
  const seen = new Set<string>()
  return {
    invocationPrefix,
    skills: skills.filter((skill) => {
      if (superseded(skill.name) || seen.has(skill.invocation)) return false
      seen.add(skill.invocation)
      return true
    }),
    ...(commands.length === 0 ? {} : { commands })
  }
}
