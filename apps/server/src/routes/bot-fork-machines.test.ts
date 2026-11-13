import { appendFileSync, mkdirSync, readFileSync, rmSync } from "node:fs"
import { join } from "node:path"

import {
  Bot as BotSchema,
  BotConversationPage,
  decode,
  FileMetadata,
  Project,
  SessionSummary,
  type AttachmentRef,
  type Bot
} from "@codevisor/api"
import { Schema } from "effect"
import { describe, expect, it } from "vitest"

import { jsonRequest, run } from "../test-support.js"
import { decodeBot } from "./bot-test-support.js"
import { laptop, post, startFleet, studio, type FleetMachine } from "./fleet-test-support.js"
import { git, tempDir, useBaseFolder } from "./project-setup-test-support.js"

const publishedRepo = async (): Promise<string> => {
  const seed = join(tempDir("codevisor-fork-seed-"), "widget")
  mkdirSync(seed)
  await git(["init", "-b", "main"], seed)
  await git(["commit", "--allow-empty", "-m", "init"], seed)
  const bare = join(tempDir("codevisor-fork-origin-"), "widget.git")
  await git(["clone", "--bare", seed, bare], seed)
  return `file://${bare}`
}

const checkedOutProject = async (machine: FleetMachine, repoUrl: string) => {
  const folder = join(tempDir("codevisor-fork-home-"), "widget")
  await git(["clone", repoUrl, folder], join(folder, ".."))
  const response = await post(machine, "/v1/projects", {
    folderPath: folder,
    id: "widget",
    name: "widget"
  })
  expect(response.status).toBe(201)
}

const botOn = async (machine: FleetMachine, projectIds: ReadonlyArray<string>): Promise<Bot> => {
  const response = await post(machine, "/v1/bots", {
    name: "Release Helper",
    symbolName: "sparkles",
    harnessId: "codex",
    projectIds
  })
  expect(response.status).toBe(201)
  return decodeBot(response.body)
}

const uploaded = async (machine: FleetMachine, bytes: string): Promise<AttachmentRef> => {
  const response = await fetch(`${machine.server.url}/v1/files?name=shot.png`, {
    method: "POST",
    headers: { "content-type": "image/png" },
    body: bytes
  })
  const file = decode(FileMetadata)(await response.json())
  return {
    fileId: file.id,
    name: file.name,
    mimeType: file.mimeType,
    sizeBytes: file.sizeBytes,
    kind: file.kind
  }
}

const conversation = async (machine: FleetMachine, bot: Bot) =>
  decode(BotConversationPage)(
    (await jsonRequest(machine.server, `/v1/sessions/${bot.sessionId}/conversation`)).body
  ).messages.map((message) => [message.sender, message.text, message.attachments?.[0]?.fileId])

const fileText = async (machine: FleetMachine, fileId: string) =>
  (await fetch(`${machine.server.url}/v1/files/${fileId}`)).text()

const sessionOn = async (machine: FleetMachine, sessionId: string) => {
  const detail = (await jsonRequest(machine.server, `/v1/sessions/${sessionId}`)).body
  return decode(Schema.Struct({ session: SessionSummary }))(detail).session
}

const queuedTexts = async (machine: FleetMachine, bot: Bot) =>
  (await run(machine.services.db.listPromptQueue(bot.sessionId))).map((item) => item.text)

const listBots = async (machine: FleetMachine) =>
  decode(Schema.Array(BotSchema))((await jsonRequest(machine.server, "/v1/bots")).body)

const listProjects = async (machine: FleetMachine) =>
  decode(Schema.Array(Project))((await jsonRequest(machine.server, "/v1/projects")).body)

const forkTo = (machine: FleetMachine, source: Bot, body: Record<string, unknown>) =>
  post(machine, `/v1/bots/${source.id}/fork`, { harnessId: "codex", ...body })

describe("forking a bot onto another machine", () => {
  it("clones its projects there and carries its notes, conversation, files and agents", async () => {
    const { home, remote } = await startFleet()
    await useBaseFolder(remote.server)
    await checkedOutProject(home, await publishedRepo())
    const source = await botOn(home, ["widget"])
    appendFileSync(join(source.rootPath, "AGENTS.md"), "\nPrefer squash merges.\n")
    const shot = await uploaded(home, "PNG-BYTES")
    await run(
      home.services.db.appendBotMessage(source.sessionId, { sender: "user", text: "Ship it" })
    )
    await run(
      home.services.db.appendBotMessage(source.sessionId, {
        sender: "bot",
        text: "Here's the release",
        attachments: [shot]
      })
    )
    const agent = decode(SessionSummary)(
      (
        await post(home, "/v1/sessions", {
          projectId: "home-project",
          harnessId: "codex",
          title: "Fix the flaky test",
          workspaceId: "4b0c6d8e-2f1a-4e3b-8c5d-6e7f8a9b0c1d",
          createdByAgentId: source.sessionId
        })
      ).body
    )

    const response = await forkTo(home, source, { toMachine: laptop.id })
    const forked = decodeBot(response.body)
    const moved = await sessionOn(home, agent.id)

    expect(response.status).toBe(201)
    expect(forked.serverId).toBe(laptop.id)
    expect((await listBots(remote)).map((bot) => bot.id)).toContain(forked.id)
    expect((await listBots(home)).map((bot) => bot.id)).not.toContain(forked.id)
    expect((await listProjects(remote)).map((project) => project.name)).toContain("widget")
    expect(forked.projects).toHaveLength(1)
    expect(readFileSync(join(forked.rootPath, "AGENTS.md"), "utf8")).toContain(
      "Prefer squash merges."
    )
    expect(await conversation(remote, forked)).toEqual([
      ["user", "Ship it", undefined],
      ["bot", "Here's the release", shot.fileId]
    ])
    expect(await fileText(remote, shot.fileId)).toBe("PNG-BYTES")
    expect([moved.createdByAgentId, moved.createdByAgentMachineId]).toEqual([
      forked.sessionId,
      laptop.id
    ])
    expect((await queuedTexts(remote, forked))[0]).toContain(
      `Fix the flaky test (agentId \`${agent.id}\` on machine ${studio.name})`
    )
  })

  it("returns the same fork when the request is sent again", async () => {
    const { home, remote } = await startFleet()
    await useBaseFolder(remote.server)
    await checkedOutProject(home, await publishedRepo())
    const source = await botOn(home, ["widget"])
    const id = "6f1c2b3a-4d5e-4f60-8a7b-9c0d1e2f3a4b"

    const first = decodeBot((await forkTo(home, source, { id, toMachine: laptop.name })).body)
    const again = decodeBot((await forkTo(home, source, { id, toMachine: laptop.name })).body)

    expect(again.id).toBe(first.id)
    expect((await listBots(remote)).filter((bot) => bot.id === id)).toHaveLength(1)
  })

  it("refuses a project with no remote, naming it, and leaves the other machine untouched", async () => {
    const { home, remote } = await startFleet()
    const source = await botOn(home, ["home-project"])

    const response = await forkTo(home, source, { toMachine: laptop.id })

    expect(response.status).toBe(422)
    expect(JSON.stringify(response.body)).toContain("home-repo has no git remote")
    expect(await listBots(remote)).toEqual([])
  })

  it("fails without leaving a bot behind when the other machine can't clone a project", async () => {
    const { home, remote } = await startFleet()
    await useBaseFolder(remote.server)
    const repoUrl = await publishedRepo()
    await checkedOutProject(home, repoUrl)
    const source = await botOn(home, ["widget"])
    rmSync(repoUrl.slice("file://".length), { recursive: true, force: true })

    const response = await forkTo(home, source, { toMachine: laptop.id })

    expect(response.status).toBe(422)
    expect(response.body).toMatchObject({ code: "invalid_url" })
    expect(await listBots(remote)).toEqual([])
  })

  it("forks onto the bot's own machine when that machine is named", async () => {
    const { home } = await startFleet()
    const source = await botOn(home, ["home-project"])

    const response = await forkTo(home, source, { toMachine: studio.id })

    expect(response.status).toBe(201)
    expect((await listBots(home)).map((bot) => bot.id)).toContain(decodeBot(response.body).id)
  })
})
