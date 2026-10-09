import type { SessionSkill, SessionSkills } from "@codevisor/api"

import type { RuntimeEvent } from "./types.js"

/// Native skills for browser and desktop tools that Codevisor's own tools
/// replace. They are Claude's skills synced from claude.ai (stored under
/// ~/.claude/skills, which OpenCode and Grok read too). With the tool gateway
/// attached, harnesses turn them off and the palette never lists them.
export const SUPERSEDED_NATIVE_SKILLS: ReadonlyArray<string> = [
  "built-in-browser",
  "chrome-browser",
  "computer-use"
]

const superseded = (name: string): boolean =>
  SUPERSEDED_NATIVE_SKILLS.includes(name.slice(name.lastIndexOf(":") + 1))

/// The session update carrying a replaceable `SessionSkills` snapshot.
export const SKILLS_UPDATE = "available_skills_update"

export const skillsUpdateEvent = (subjectId: string, skills: SessionSkills): RuntimeEvent => ({
  kind: "session.output",
  subjectId,
  payload: { sessionUpdate: SKILLS_UPDATE, ...skills }
})

/// One snapshot per invocation: harnesses can list a skill twice (a project
/// copy shadowing a user one), and the first listing is the one that runs.
/// Superseded native skills are left out, plugin-qualified or not.
export const sessionSkills = (
  skills: ReadonlyArray<SessionSkill>,
  invocationPrefix: string
): SessionSkills => {
  const seen = new Set<string>()
  return {
    invocationPrefix,
    skills: skills.filter((skill) => {
      if (superseded(skill.name) || seen.has(skill.invocation)) return false
      seen.add(skill.invocation)
      return true
    })
  }
}
