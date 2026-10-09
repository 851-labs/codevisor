import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { makeSkillStore } from "@codevisor/skills"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import type { CodevisorServerServices } from "../server-context.js"
import {
  jsonRequest,
  listSubjectEvents,
  makeServices,
  run,
  runningServers,
  startWithApp,
  tempDirs,
  waitFor
} from "../test-support.js"
import { expandCodevisorSkills, withCodevisorSkills } from "./prompt-skills.js"

const NOTE =
  "The user invoked the Codevisor skill `release-notes`. Before anything else, read it with the Codevisor `skills` tool (pass the skill's name) and follow its instructions for this request."

describe("Codevisor skills in prompts", () => {
  it("turns a store skill's token into text and asks the agent to load it", () => {
    expect(expandCodevisorSkills("/release-notes for v2.", ["release-notes"], undefined)).toBe(
      `\`release-notes\` for v2.\n\n<codevisor-skills>\n${NOTE}\n</codevisor-skills>`
    )
    // Codex users invoke with `$`; a sentence can end right after the name.
    expect(expandCodevisorSkills("then $release-notes.", ["release-notes"], undefined)).toBe(
      `then \`release-notes\`.\n\n<codevisor-skills>\n${NOTE}\n</codevisor-skills>`
    )
  })

  it("names every invoked store skill once", () => {
    expect(
      expandCodevisorSkills("$triage then $ship, then $triage again", ["triage", "ship"], undefined)
    ).toBe(
      "`triage` then `ship`, then `triage` again\n\n<codevisor-skills>\nThe user invoked these Codevisor skills `triage`, `ship`. Before anything else, read each one with the Codevisor `skills` tool (pass the skill's name) and follow their instructions for this request.\n</codevisor-skills>"
    )
  })

  it("sends the prompt unchanged when the skill list can't be read", async () => {
    const services = {
      db: { getSessionSummary: () => Effect.fail(new Error("gone")) },
      mcp: {}
    } as unknown as CodevisorServerServices
    expect(await withCodevisorSkills(services, "session", "/release-notes", undefined)).toBe(
      "/release-notes"
    )
    expect(await withCodevisorSkills({} as never, "session", "/release-notes", undefined)).toBe(
      "/release-notes"
    )
  })

  it("leaves harness skills, skills not offered, and paths alone", () => {
    const native = { invocationPrefix: "/", skills: [{ invocation: "/review", name: "review" }] }
    expect(expandCodevisorSkills("/review it", ["review"], native)).toBe("/review it")
    const prompt = "/review src/release-notes and /execute the plan"
    expect(expandCodevisorSkills(prompt, ["review", "release-notes"], native)).toBe(prompt)
  })

  it("sends the rewrite to the harness and keeps the user's text in the transcript", async () => {
    const skillsDir = mkdtempSync(join(tmpdir(), "codevisor-skills-"))
    tempDirs.push(skillsDir)
    const skills = makeSkillStore({ dir: skillsDir })
    await skills.create({ description: "Draft release notes", name: "release-notes" })
    const { agents, services } = await makeServices("server-a", { skillSource: skills })
    const server = await startWithApp({ ...services, skills })
    runningServers.push(server)
    const folderPath = mkdtempSync(join(tmpdir(), "codevisor-prompt-skills-"))
    tempDirs.push(folderPath)
    const project = await run(services.db.createProject({ folderPath }))
    const session = await run(
      services.db.createSession({ harnessId: "codex", projectId: project.id })
    )

    await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
      body: JSON.stringify({ text: "/release-notes for v2." }),
      method: "POST"
    })
    await waitFor(() => agents.prompts.length === 1)

    expect(agents.prompts[0]?.[1]).toBe(
      `\`release-notes\` for v2.\n\n<codevisor-skills>\n${NOTE}\n</codevisor-skills>`
    )
    const transcript = await jsonRequest(server, `/v1/sessions/${session.id}/transcript`)
    const items = (transcript.body as { items: ReadonlyArray<unknown> }).items
    expect(items[0]).toMatchObject({ role: "user", text: "/release-notes for v2." })
  })

  it("records the skills a harness reports while starting, once", async () => {
    const { services } = await makeServices("server-a")
    const server = await startWithApp(services)
    runningServers.push(server)
    const folderPath = mkdtempSync(join(tmpdir(), "codevisor-native-skills-"))
    tempDirs.push(folderPath)
    const project = await run(services.db.createProject({ folderPath }))
    const session = await run(
      services.db.createSession({ harnessId: "codex", projectId: project.id })
    )

    for (let connect = 0; connect < 2; connect += 1) {
      const connected = await jsonRequest(server, `/v1/sessions/${session.id}/connect`, {
        method: "POST"
      })
      expect(connected.status).toBe(200)
    }

    // A fresh session in the same folder offers them before it starts.
    const capabilities = await jsonRequest(
      server,
      `/v1/capabilities?cwd=${encodeURIComponent(folderPath)}`
    )
    expect(capabilities.body).toMatchObject({
      harnesses: [{ skills: { skills: [{ name: "review" }] } }]
    })
    const transcript = await jsonRequest(server, `/v1/sessions/${session.id}/transcript`)
    expect(transcript.body).toMatchObject({
      skills: {
        invocationPrefix: "/",
        skills: [{ invocation: "/review", name: "review", source: "builtin" }]
      }
    })
    expect(
      listSubjectEvents(services, session.id).filter(
        (event) =>
          (event.payload as { sessionUpdate?: string }).sessionUpdate === "available_skills_update"
      )
    ).toHaveLength(1)
  })

  it("offers each chat the Codevisor skills its enabled tools allow", async () => {
    const skillsDir = mkdtempSync(join(tmpdir(), "codevisor-skills-"))
    tempDirs.push(skillsDir)
    const skills = makeSkillStore({ dir: skillsDir })
    await skills.create({ description: "Draft release notes", name: "release-notes" })
    const { services } = await makeServices("server-a", { skillSource: skills })
    const server = await startWithApp(services)
    runningServers.push(server)
    const folderPath = mkdtempSync(join(tmpdir(), "codevisor-composer-skills-"))
    tempDirs.push(folderPath)
    const project = await run(services.db.createProject({ folderPath }))
    const offered = async () =>
      (
        (await jsonRequest(server, `/v1/composer-skills?projectId=${project.id}`)).body as {
          skills: ReadonlyArray<{ name: string }>
        }
      ).skills.map((skill) => skill.name)

    expect(await offered()).toEqual([
      "browser-use",
      "computer-use",
      "codevisor-agents",
      "release-notes"
    ])
    // A guide leaves with its tool.
    await services.mcp.setProjectEnabled(project.id, "computer", false)
    expect(await offered()).toEqual(["browser-use", "codevisor-agents", "release-notes"])

    // Without a tool gateway no Codevisor skill can load.
    const { mcp: _gateway, ...withoutGateway } = services
    const gatewayless = await startWithApp(withoutGateway)
    runningServers.push(gatewayless)
    expect((await jsonRequest(gatewayless, "/v1/composer-skills?projectId=")).body).toEqual({
      skills: []
    })
  })
})
