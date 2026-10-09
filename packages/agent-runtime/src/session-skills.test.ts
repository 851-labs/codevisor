import { describe, expect, it } from "vitest"

import { sessionSkills, skillsUpdateEvent } from "./session-skills.js"

describe("session skills", () => {
  it("keeps the first listing of each invocation and drops superseded skills", () => {
    const skills = sessionSkills(
      [
        { invocation: "/review", name: "review", source: "project" },
        { invocation: "/review", name: "review", source: "user" },
        { invocation: "/ship", name: "ship" },
        // Codevisor's own browser and desktop tools replace these.
        { invocation: "/computer-use", name: "computer-use" },
        { invocation: "/anthropic-skills:chrome-browser", name: "anthropic-skills:chrome-browser" }
      ],
      "/"
    )
    expect(skills).toEqual({
      invocationPrefix: "/",
      skills: [
        { invocation: "/review", name: "review", source: "project" },
        { invocation: "/ship", name: "ship" }
      ]
    })
    expect(skillsUpdateEvent("session-1", skills)).toEqual({
      kind: "session.output",
      payload: { sessionUpdate: "available_skills_update", ...skills },
      subjectId: "session-1"
    })
  })
})
