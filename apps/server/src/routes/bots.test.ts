import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"

import { decode, Project, SessionDetail, Workspace, WorkspacePane } from "@codevisor/api"
import { botsRoot } from "@codevisor/db"
import { worktreeTrashQueue } from "@codevisor/worktrees"
import { Effect, Schema } from "effect"
import { describe, expect, it, onTestFinished, vi } from "vitest"

import { jsonRequest, listEvents, waitFor } from "../test-support.js"
import { createBot, decodeBot, git, listBots, listProjects, setUp } from "./bot-test-support.js"

describe("bot routes", () => {
  it("creates a bot with a worktree per repo, instructions, and a started chat", async () => {
    const running = await setUp()
    const apiFolder = await running.addProject("api-project", "api")
    const webFolder = await running.addProject("web-project", "web")

    const response = await createBot(running, {
      projectIds: ["web-project", "api-project", "WEB-PROJECT"],
      configSelections: { model: "gpt-5", effort: "high" }
    })

    expect(response.status).toBe(201)
    const bot = decodeBot(response.body)
    const root = join(botsRoot(), "release-helper")
    expect(bot).toMatchObject({
      name: "Release Helper",
      symbolName: "sparkles",
      harnessId: "codex",
      rootPath: root,
      projects: [
        { projectId: "web-project", folderName: "web", branch: "codevisor/bot-release-helper" },
        { projectId: "api-project", folderName: "api", branch: "codevisor/bot-release-helper" }
      ]
    })
    expect(await git(["branch", "--show-current"], join(root, "web"))).toBe(
      "codevisor/bot-release-helper"
    )
    expect(await git(["branch", "--show-current"], join(root, "api"))).toBe(
      "codevisor/bot-release-helper"
    )
    const instructions = readFileSync(join(root, "AGENTS.md"), "utf8")
    expect(instructions).toContain(`\`web/\`: web (from \`${webFolder}\``)
    expect(instructions).toContain(`\`api/\`: api (from \`${apiFolder}\``)
    expect(instructions).toContain("projectId `api-project`")
    expect(instructions).toContain("## Delegating work")
    expect(instructions).not.toContain("`machines.current.tools.codevisor.messages.send`")
    expect(instructions).toContain("`machines.current.agents.start({ project: projectId")
    expect(existsSync(join(root, "CLAUDE.md"))).toBe(false)

    const home = (await listProjects(running)).find((project) => project.id === bot.projectId)
    expect(home).toMatchObject({
      name: "Release Helper",
      isBot: true,
      locations: [{ folderPath: root, isGitRepository: false }]
    })
    const { session } = decode(SessionDetail)(
      (await jsonRequest(running.server, `/v1/sessions/${bot.sessionId}`)).body
    )
    expect(session).toMatchObject({
      projectId: bot.projectId,
      workspaceId: bot.workspaceId,
      harnessId: "codex",
      title: "Release Helper",
      cwd: root
    })
    expect(running.agents.creations).toContainEqual(["codex", root])
    expect(running.agents.startSelections).toContainEqual({ model: "gpt-5", effort: "high" })
    const workspaces = decode(Schema.Array(Workspace))(
      (await jsonRequest(running.server, "/v1/workspaces")).body
    )
    expect(workspaces.find((workspace) => workspace.id === bot.workspaceId)).toMatchObject({
      projectId: bot.projectId
    })
    const panes = decode(Schema.Array(WorkspacePane))(
      (await jsonRequest(running.server, "/v1/workspace-panes")).body
    )
    expect(panes).toContainEqual(
      expect.objectContaining({ workspaceId: bot.workspaceId, resourceId: bot.sessionId })
    )
    expect(await listBots(running)).toEqual([bot])
    expect(listEvents(running.services)).toContainEqual(
      expect.objectContaining({ kind: "bot.updated", subjectId: bot.id })
    )
  })

  it("returns the existing bot when a create request is repeated", async () => {
    const running = await setUp()
    await running.addProject("api-project", "api")
    const body = { id: "4e6f1d1b-3c2a-4b8e-9f00-000000000001", projectIds: ["api-project"] }

    const first = await createBot(running, body)
    const repeated = await createBot(running, body)

    expect(first.status).toBe(201)
    expect(repeated.status).toBe(200)
    expect(repeated.body).toEqual(first.body)
    expect(await listBots(running)).toHaveLength(1)
    expect(existsSync(join(botsRoot(), "release-helper-2"))).toBe(false)
  })

  it("gives a second bot with the same name its own folder and branch", async () => {
    const running = await setUp()
    await running.addProject("api-project", "api")

    const first = decodeBot((await createBot(running, { projectIds: ["api-project"] })).body)
    const second = decodeBot((await createBot(running, { projectIds: ["api-project"] })).body)

    expect(first.rootPath).toBe(join(botsRoot(), "release-helper"))
    expect(second.rootPath).toBe(join(botsRoot(), "release-helper-2"))
    expect(second.projects[0]?.branch).toBe("codevisor/bot-release-helper-2")
  })

  it("falls back to generic folder names when names have no usable characters", async () => {
    const running = await setUp()
    await running.addProject("symbols-project", "日本")

    const bot = decodeBot(
      (await createBot(running, { name: "🤖", projectIds: ["symbols-project"] })).body
    )

    expect(bot.rootPath).toBe(join(botsRoot(), "bot"))
    expect(bot.projects).toEqual([
      expect.objectContaining({ folderName: "repo", branch: "codevisor/bot-bot" })
    ])
  })

  it("rejects bots without a name or with projects that cannot be checked out", async () => {
    const running = await setUp()
    await running.addProject("api-project", "api")
    const plain = join(running.repoRoot, "plain")
    mkdirSync(plain)
    await jsonRequest(running.server, "/v1/projects", {
      body: JSON.stringify({ folderPath: plain, id: "plain-project" }),
      method: "POST"
    })
    const scratch = await jsonRequest(running.server, "/v1/projects/scratch", {
      body: JSON.stringify({}),
      method: "POST"
    })
    const scratchId = decode(Project)(scratch.body).id
    const bot = decodeBot((await createBot(running, { projectIds: ["api-project"] })).body)

    for (const body of [
      { name: "  ", projectIds: ["api-project"] },
      { projectIds: [] },
      { projectIds: ["plain-project"] },
      { projectIds: [scratchId] },
      { projectIds: [bot.projectId] }
    ]) {
      expect((await createBot(running, body)).status).toBe(422)
    }
    expect((await createBot(running, { projectIds: ["missing"] })).status).toBe(404)
    expect(await listBots(running)).toEqual([bot])
  })

  it.each([
    ["a repo's start point cannot be resolved", "checkout"],
    ["git fails part way through checking a repo out", "hook"],
    ["the chat cannot start", "agent"],
    ["the bot cannot be saved", "record"]
  ] as const)("leaves nothing behind when %s", async (_label, failure) => {
    const running = await setUp()
    const apiFolder = await running.addProject("api-project", "api")
    const webFolder = await running.addProject("web-project", "web")
    if (failure === "checkout") {
      await jsonRequest(running.server, "/v1/projects/web-project", {
        body: JSON.stringify({ worktreeBase: { remote: "origin", branch: "missing" } }),
        method: "PATCH"
      })
    } else if (failure === "hook") {
      const hook = join(webFolder, ".git", "hooks", "post-checkout")
      mkdirSync(dirname(hook), { recursive: true })
      writeFileSync(hook, "#!/bin/sh\nexit 1\n", { mode: 0o755 })
    } else if (failure === "agent") {
      vi.spyOn(running.agents, "createAgentSession").mockReturnValueOnce(
        Effect.die(new Error("harness is not signed in"))
      )
    } else {
      vi.spyOn(running.services.db, "createBot").mockReturnValueOnce(
        Effect.die(new Error("disk full"))
      )
    }
    const projectsBefore = await listProjects(running)
    const closesBefore = running.agents.closes.length
    const deleting = Promise.withResolvers<void>()
    const busyTrash = vi.spyOn(worktreeTrashQueue, "enqueue").mockReturnValue(deleting.promise)
    onTestFinished(() => {
      deleting.resolve()
      busyTrash.mockRestore()
    })

    const response = await createBot(running, { projectIds: ["api-project", "web-project"] })

    expect(response.status).toBeGreaterThanOrEqual(400)
    expect(busyTrash).toHaveBeenCalled()
    expect(existsSync(join(botsRoot(), "release-helper"))).toBe(false)
    for (const folder of [apiFolder, webFolder]) {
      expect(await git(["branch", "--list", "codevisor/*"], folder)).toBe("")
      expect(await git(["worktree", "list", "--porcelain"], folder)).not.toContain("release-helper")
    }
    expect(await listProjects(running)).toEqual(projectsBefore)
    expect(await listBots(running)).toEqual([])
    expect(running.agents.closes.length > closesBefore).toBe(failure === "record")
    const deletedKinds = new Set(listEvents(running.services).map((event) => event.kind))
    expect(deletedKinds.has("session.deleted")).toBe(failure === "record")
    expect(deletedKinds.has("workspace.deleted")).toBe(failure === "record")
  })

  it("renames a bot, its chat title, and its icon", async () => {
    const running = await setUp()
    await running.addProject("api-project", "api")
    const bot = decodeBot((await createBot(running, { projectIds: ["api-project"] })).body)

    const renamed = await jsonRequest(running.server, `/v1/bots/${bot.id}`, {
      body: JSON.stringify({ name: " Reviewer ", symbolName: "ant" }),
      method: "PATCH"
    })

    expect(renamed.status).toBe(200)
    expect(decodeBot(renamed.body)).toMatchObject({ name: "Reviewer", symbolName: "ant" })
    const instructions = readFileSync(join(bot.rootPath, "AGENTS.md"), "utf8")
    expect(instructions.startsWith("# Reviewer\n")).toBe(true)
    expect(instructions).toContain("## Delegating work")
    const { session } = decode(SessionDetail)(
      (await jsonRequest(running.server, `/v1/sessions/${bot.sessionId}`)).body
    )
    expect(session.title).toBe("Reviewer")
    expect(
      (await listProjects(running)).find((project) => project.id === bot.projectId)?.name
    ).toBe("Reviewer")
    const workspaces = decode(Schema.Array(Workspace))(
      (await jsonRequest(running.server, "/v1/workspaces")).body
    )
    expect(workspaces.find((workspace) => workspace.id === bot.workspaceId)?.name).toBe("Reviewer")
    const nameOnly = await jsonRequest(running.server, `/v1/bots/${bot.id}`, {
      body: JSON.stringify({ name: "Reviewer" }),
      method: "PATCH"
    })
    expect(decodeBot(nameOnly.body)).toMatchObject({ name: "Reviewer", symbolName: "ant" })
    const iconOnly = await jsonRequest(running.server, `/v1/bots/${bot.id}`, {
      body: JSON.stringify({ symbolName: "brain" }),
      method: "PATCH"
    })
    expect(decodeBot(iconOnly.body)).toMatchObject({ name: "Reviewer", symbolName: "brain" })
    rmSync(join(bot.rootPath, "AGENTS.md"))
    const withoutInstructions = await jsonRequest(running.server, `/v1/bots/${bot.id}`, {
      body: JSON.stringify({ name: "Editor" }),
      method: "PATCH"
    })
    expect(withoutInstructions.status).toBe(200)
    const blank = await jsonRequest(running.server, `/v1/bots/${bot.id}`, {
      body: JSON.stringify({ name: "" }),
      method: "PATCH"
    })
    expect(blank.status).toBe(422)
    const missing = await jsonRequest(running.server, "/v1/bots/missing", {
      body: JSON.stringify({ name: "Nope" }),
      method: "PATCH"
    })
    expect(missing.status).toBe(404)
  })

  it("switches a bot's conversation mode, rewrites its instructions, and tells the bot", async () => {
    const running = await setUp()
    await running.addProject("api-project", "api")
    const bot = decodeBot((await createBot(running, { projectIds: ["api-project"] })).body)
    const plain = readFileSync(join(bot.rootPath, "AGENTS.md"), "utf8")
    const prompts = () =>
      running.agents.prompts.map(([, input]) => (typeof input === "string" ? input : input.text))
    const setConversational = (conversational: boolean) =>
      jsonRequest(running.server, `/v1/bots/${bot.id}`, {
        body: JSON.stringify({ conversational }),
        method: "PATCH"
      })

    const turnedOn = await setConversational(true)

    expect(decodeBot(turnedOn.body)).toMatchObject({ name: bot.name, conversational: true })
    expect(await listBots(running)).toEqual([decodeBot(turnedOn.body)])
    const conversational = readFileSync(join(bot.rootPath, "AGENTS.md"), "utf8")
    expect(conversational).toContain("## Talking to the user")
    expect(conversational).toContain("Codevisor sends you a `<codevisor-event>`")
    await waitFor(() => prompts().length === 1)
    expect(prompts()[0]).toContain('<codevisor-event type="bot.conversation_mode_changed">')
    expect(prompts()[0]).toContain("turned on conversation mode")

    await setConversational(true)
    const turnedOff = await setConversational(false)

    expect(decodeBot(turnedOff.body).conversational).toBe(false)
    expect(readFileSync(join(bot.rootPath, "AGENTS.md"), "utf8")).toBe(plain)
    await waitFor(() => prompts().length === 2)
    expect(prompts()[1]).toContain("turned off conversation mode")
  })

  it("protects a bot's projects, workspace, and chat until the bot is deleted", async () => {
    const running = await setUp()
    const apiFolder = await running.addProject("api-project", "api")
    const bot = decodeBot((await createBot(running, { projectIds: ["api-project"] })).body)

    const attempts: ReadonlyArray<readonly [string, RequestInit]> = [
      ["/v1/projects/api-project", { method: "DELETE" }],
      [`/v1/projects/${bot.projectId}`, { method: "DELETE" }],
      [`/v1/sessions/${bot.sessionId}`, { method: "DELETE" }],
      [`/v1/workspaces/${bot.workspaceId}`, { method: "DELETE" }],
      [
        `/v1/workspaces/${bot.workspaceId}`,
        { method: "PATCH", body: JSON.stringify({ isArchived: true }) }
      ],
      [
        `/v1/workspaces/${bot.workspaceId}`,
        {
          method: "PUT",
          body: JSON.stringify({
            projectId: bot.projectId,
            name: "Release Helper",
            hasCustomName: false,
            isArchived: true
          })
        }
      ]
    ]
    for (const [path, init] of attempts) {
      expect((await jsonRequest(running.server, path, init)).status).toBe(409)
    }

    expect(
      (await jsonRequest(running.server, `/v1/bots/${bot.id}`, { method: "DELETE" })).status
    ).toBe(204)

    expect(existsSync(bot.rootPath)).toBe(false)
    expect(await git(["branch", "--list", "codevisor/*"], apiFolder)).toBe("")
    expect(await listBots(running)).toEqual([])
    expect((await listProjects(running)).map((project) => project.id)).toEqual(["api-project"])
    expect(running.agents.closes.length).toBeGreaterThan(0)
    expect(
      (await jsonRequest(running.server, `/v1/bots/${bot.id}`, { method: "DELETE" })).status
    ).toBe(204)
    expect(
      (await jsonRequest(running.server, "/v1/projects/api-project", { method: "DELETE" })).status
    ).toBe(204)
  })

  it("deletes a bot even when one of its source repos is gone", async () => {
    const running = await setUp()
    const apiFolder = await running.addProject("api-project", "api")
    const webFolder = await running.addProject("web-project", "web")
    const bot = decodeBot(
      (await createBot(running, { projectIds: ["api-project", "web-project"] })).body
    )
    rmSync(apiFolder, { recursive: true, force: true })

    const deleted = await jsonRequest(running.server, `/v1/bots/${bot.id}`, { method: "DELETE" })

    expect(deleted.status).toBe(204)
    expect(await listBots(running)).toEqual([])
    expect(existsSync(bot.rootPath)).toBe(false)
    expect(await git(["branch", "--list", "codevisor/*"], webFolder)).toBe("")
  })

  it("ignores unsupported bot methods", async () => {
    const running = await setUp()
    expect((await jsonRequest(running.server, "/v1/bots", { method: "PUT" })).status).toBe(404)
    expect((await jsonRequest(running.server, "/v1/bots/some-bot")).status).toBe(404)
  })
})
