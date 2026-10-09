import { describe, expect, it } from "vitest"

import { run, setup } from "./test-support.js"

const skill = (name: string, fields: Record<string, unknown> = {}) => ({
  description: `${name} description`,
  enabled: true,
  name,
  path: `/skills/${name}/SKILL.md`,
  pluginId: null,
  scope: "user",
  ...fields
})

describe("Codex skills", () => {
  it("lists the skills the thread can run as $ invocations", async () => {
    const { created } = await setup({
      listedSkills: [
        skill("triage", { interface: { shortDescription: "Triage flaky CI" }, scope: "repo" }),
        skill("notes"),
        skill("release", { pluginId: "release@acme" }),
        // Codevisor threads turn these off, whatever the user's config says.
        skill("skill-creator", { scope: "system" }),
        skill("pdf:pdf", { pluginId: "pdf@openai-bundled" }),
        skill("cua", { pluginId: "unified-computer-use@openai-bundled" }),
        skill("off", { enabled: false })
      ]
    })

    expect(created?.metadata.skills).toEqual({
      invocationPrefix: "$",
      skills: [
        {
          description: "Triage flaky CI",
          invocation: "$triage",
          name: "triage",
          source: "project"
        },
        { description: "notes description", invocation: "$notes", name: "notes", source: "user" },
        {
          description: "release description",
          invocation: "$release",
          name: "release",
          source: "plugin"
        }
      ]
    })
  })

  it("sends each mentioned skill as a skill item", async () => {
    const { client, created } = await setup({ listedSkills: [skill("triage"), skill("notes")] })
    const prompt = run(created!.handle.prompt("$triage the CI failure, then $notes."))
    await Promise.resolve()
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "t", status: "completed" }
    })
    await prompt

    const turnStart = client.requests.find((request) => request.method === "turn/start")
    expect(turnStart?.params).toMatchObject({
      input: [
        { text: "$triage the CI failure, then $notes.", type: "text" },
        { name: "triage", path: "/skills/triage/SKILL.md", type: "skill" },
        { name: "notes", path: "/skills/notes/SKILL.md", type: "skill" }
      ]
    })
  })

  it("re-lists skills when Codex reports a change", async () => {
    const { client, nextEvent } = await setup({ listedSkills: [skill("triage")] })
    client.listedSkills = [skill("triage"), skill("ship")]

    const update = nextEvent(
      (event) =>
        (event.payload as { sessionUpdate?: unknown }).sessionUpdate === "available_skills_update"
    )
    client.emit("skills/changed", {})

    expect((await update).payload).toMatchObject({
      sessionUpdate: "available_skills_update",
      skills: [{ name: "triage" }, { name: "ship" }]
    })
    expect(client.requests.at(-1)).toEqual({
      method: "skills/list",
      params: { cwds: ["/tmp/project"], forceReload: true }
    })
  })
})
