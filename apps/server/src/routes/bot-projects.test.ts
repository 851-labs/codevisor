import { existsSync, mkdirSync, readFileSync } from "node:fs"
import { join } from "node:path"

import { decode, SessionSummary } from "@codevisor/api"
import { Effect } from "effect"
import { describe, expect, it, vi } from "vitest"

import { jsonRequest, listEvents, waitFor } from "../test-support.js"
import { createBot, decodeBot, git, listBots, setUp, type Running } from "./bot-test-support.js"

const addProject = (running: Running, path: string, projectId: string) =>
  jsonRequest(running.server, path, {
    body: JSON.stringify({ projectId }),
    method: "POST"
  })

const removeProject = (running: Running, path: string, projectId: string) =>
  jsonRequest(running.server, `${path}/${projectId}`, { method: "DELETE" })

const promptTexts = (running: Running): ReadonlyArray<string> =>
  running.agents.prompts.map(([, input]) => (typeof input === "string" ? input : input.text))

const instructions = (rootPath: string): string => readFileSync(join(rootPath, "AGENTS.md"), "utf8")

describe("bot projects", () => {
  it("checks out a project added later, lists it, and tells the bot", async () => {
    const running = await setUp()
    await running.addProject("api-project", "api")
    const webFolder = await running.addProject("web-project", "web")
    const bot = decodeBot((await createBot(running, { projectIds: ["api-project"] })).body)

    const [added, repeated] = await Promise.all([
      addProject(running, `/v1/bots/${bot.id}/projects`, "web-project"),
      addProject(running, `/v1/bots/${bot.id}/projects`, "WEB-PROJECT")
    ])

    expect(added.status).toBe(200)
    expect(repeated.status).toBe(200)
    const updated = decodeBot(repeated.body)
    expect(updated.projects).toEqual([
      expect.objectContaining({ projectId: "api-project", folderName: "api" }),
      {
        projectId: "web-project",
        folderName: "web",
        branch: "codevisor/bot-release-helper",
        path: join(bot.rootPath, "web")
      }
    ])
    expect(await listBots(running)).toEqual([updated])
    expect(await git(["branch", "--show-current"], join(bot.rootPath, "web"))).toBe(
      "codevisor/bot-release-helper"
    )
    const text = instructions(bot.rootPath)
    expect(text).toContain(`\`web/\`: web (from \`${webFolder}\`, projectId \`web-project\`)`)
    expect(text).toContain("`bot.projects_add({ projectId })`")
    expect(text.indexOf("`web/`")).toBeLessThan(text.indexOf("## Delegating work"))
    expect(
      listEvents(running.services).filter(
        (event) => event.kind === "bot.updated" && event.subjectId === bot.id
      )
    ).toHaveLength(2)
    await waitFor(() => promptTexts(running).length === 1)
    expect(promptTexts(running)[0]).toContain('<codevisor-event type="bot.projects_changed">')
    expect(promptTexts(running)[0]).toContain("added the repository web")
  })

  it("removes a project's checkout, frees the project, and keeps the last one", async () => {
    const running = await setUp()
    const apiFolder = await running.addProject("api-project", "api")
    await running.addProject("web-project", "web")
    const bot = decodeBot(
      (await createBot(running, { projectIds: ["api-project", "web-project"] })).body
    )

    const removed = await removeProject(running, `/v1/bots/${bot.id}/projects`, "api-project")

    expect(removed.status).toBe(200)
    expect(decodeBot(removed.body).projects.map((project) => project.projectId)).toEqual([
      "web-project"
    ])
    expect(existsSync(join(bot.rootPath, "api"))).toBe(false)
    expect(await git(["branch", "--list", "codevisor/*"], apiFolder)).toBe("")
    expect(instructions(bot.rootPath)).not.toContain("`api/`")
    await waitFor(() => promptTexts(running).length === 1)
    expect(promptTexts(running)[0]).toContain("removed the repository api")
    expect(
      (await jsonRequest(running.server, "/v1/projects/api-project", { method: "DELETE" })).status
    ).toBe(204)
    expect(
      (await removeProject(running, `/v1/bots/${bot.id}/projects`, "api-project")).status
    ).toBe(404)
    expect(
      (await removeProject(running, `/v1/bots/${bot.id}/projects`, "web-project")).status
    ).toBe(422)
    expect((await removeProject(running, "/v1/bots/missing/projects", "web-project")).status).toBe(
      404
    )
  })

  it("leaves the bot unchanged when a project cannot be checked out", async () => {
    const running = await setUp()
    await running.addProject("api-project", "api")
    const plain = join(running.repoRoot, "plain")
    mkdirSync(plain)
    await jsonRequest(running.server, "/v1/projects", {
      body: JSON.stringify({ folderPath: plain, id: "plain-project" }),
      method: "POST"
    })
    const bot = decodeBot((await createBot(running, { projectIds: ["api-project"] })).body)
    const before = instructions(bot.rootPath)

    expect((await addProject(running, `/v1/bots/${bot.id}/projects`, "plain-project")).status).toBe(
      422
    )
    expect((await addProject(running, `/v1/bots/${bot.id}/projects`, bot.projectId)).status).toBe(
      422
    )
    expect((await addProject(running, `/v1/bots/${bot.id}/projects`, "missing")).status).toBe(404)

    expect(await listBots(running)).toEqual([bot])
    expect(instructions(bot.rootPath)).toBe(before)
    expect(promptTexts(running)).toEqual([])
  })

  it("rolls back a checkout it could not record and still applies the next change", async () => {
    const running = await setUp()
    await running.addProject("api-project", "api")
    const webFolder = await running.addProject("web-project", "web")
    await running.addProject("docs-project", "docs")
    const bot = decodeBot((await createBot(running, { projectIds: ["api-project"] })).body)
    vi.spyOn(running.services.db, "addBotProject").mockReturnValueOnce(
      Effect.die(new Error("disk full"))
    )

    const [failed, next] = await Promise.all([
      addProject(running, `/v1/bots/${bot.id}/projects`, "web-project"),
      addProject(running, `/v1/bots/${bot.id}/projects`, "docs-project")
    ])

    expect(failed.status).toBe(500)
    expect(await git(["branch", "--list", "codevisor/*"], webFolder)).toBe("")
    expect(existsSync(join(bot.rootPath, "web"))).toBe(false)
    expect(decodeBot(next.body).projects.map((project) => project.folderName)).toEqual([
      "api",
      "docs"
    ])
  })

  it("lets only the bot's own chat change its projects, without telling it what it did", async () => {
    const running = await setUp()
    await running.addProject("api-project", "api")
    await running.addProject("web-project", "web")
    const bot = decodeBot((await createBot(running, { projectIds: ["api-project"] })).body)
    const child = await jsonRequest(running.server, "/v1/sessions", {
      body: JSON.stringify({ projectId: "api-project", harnessId: "codex", title: "Child" }),
      method: "POST"
    })
    const childId = decode(SessionSummary)(child.body).id

    const added = await addProject(
      running,
      `/v1/sessions/${bot.sessionId}/bot/projects`,
      "web-project"
    )
    const removed = await removeProject(
      running,
      `/v1/sessions/${bot.sessionId}/bot/projects`,
      "api-project"
    )
    const refused = await addProject(running, `/v1/sessions/${childId}/bot/projects`, "api-project")

    expect(added.status).toBe(200)
    expect(decodeBot(removed.body).projects.map((project) => project.projectId)).toEqual([
      "web-project"
    ])
    expect(refused.status).toBe(403)
    expect(promptTexts(running)).toEqual([])
  })
})
