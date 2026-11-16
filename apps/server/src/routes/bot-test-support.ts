import { execFile } from "node:child_process"
import { mkdirSync, mkdtempSync, realpathSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import { Bot, decode, Project } from "@codevisor/api"
import { Schema } from "effect"
import { expect, onTestFinished } from "vitest"

import type { CodevisorServerConfig, RunningCodevisorServer } from "../server.js"
import { jsonRequest, listSubjectEvents, start, tempDirs, waitFor } from "../test-support.js"
import { GREETING_OPENING } from "./bot-greeting-text.js"

const execFileAsync = promisify(execFile)
export const git = async (args: ReadonlyArray<string>, cwd: string): Promise<string> =>
  (await execFileAsync("git", [...args], { cwd })).stdout.trim()
export const decodeBot = decode(Bot)

const useWorktreesRoot = (): string => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "codevisor-bot-root-")))
  tempDirs.push(root)
  process.env["CODEVISOR_WORKTREES_ROOT"] = root
  onTestFinished(() => {
    delete process.env["CODEVISOR_WORKTREES_ROOT"]
  })
  return root
}

export const setUp = (configOverrides: Partial<CodevisorServerConfig> = {}) =>
  setUpWith(() => start(undefined, {}, configOverrides))

export const setUpWith = async <Started extends { readonly server: RunningCodevisorServer }>(
  startServer: () => Promise<Started>
) => {
  useWorktreesRoot()
  const running = await startServer()
  const repoRoot = realpathSync(mkdtempSync(join(tmpdir(), "codevisor-bot-repos-")))
  tempDirs.push(repoRoot)
  const addProject = async (id: string, name: string): Promise<string> => {
    const folder = join(repoRoot, name)
    mkdirSync(folder)
    await git(["init", "-b", "main"], folder)
    await git(
      ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init"],
      folder
    )
    const response = await jsonRequest(running.server, "/v1/projects", {
      body: JSON.stringify({ folderPath: folder, id, name }),
      method: "POST"
    })
    expect(response.status).toBe(201)
    return folder
  }
  return { ...running, addProject, repoRoot }
}

export type Running = Awaited<ReturnType<typeof setUp>>

type Introduced = Pick<Running, "server" | "services" | "agents">

const introducedSessions = new WeakMap<Introduced["services"], Set<string>>()

const introductionsOf = (running: Pick<Running, "services">): Set<string> => {
  const known = introducedSessions.get(running.services) ?? new Set<string>()
  introducedSessions.set(running.services, known)
  return known
}

const everyEndedTurn = (running: Pick<Running, "services">, sessionId: string): number =>
  listSubjectEvents(running.services, sessionId).filter(
    (event) =>
      event.kind === "session.updated" &&
      JSON.stringify(event.payload).includes('"turnState":"ended"')
  ).length

export const endedTurns = (running: Pick<Running, "services">, sessionId: string) =>
  everyEndedTurn(running, sessionId) - (introductionsOf(running).has(sessionId) ? 1 : 0)

const isIntroduction = (input: string | { readonly text: string }): boolean =>
  (typeof input === "string" ? input : input.text).startsWith(GREETING_OPENING)

export const postBot = (running: Pick<Running, "server">, body: Record<string, unknown>) =>
  jsonRequest(running.server, "/v1/bots", {
    body: JSON.stringify({
      name: "Release Helper",
      symbolName: "sparkles",
      harnessId: "codex",
      ...body
    }),
    method: "POST"
  })

export const createBot = async (running: Introduced, body: Record<string, unknown>) => {
  const response = await postBot(running, body)
  if (response.status === 201) await introduced(running, decodeBot(response.body).sessionId)
  return response
}

const introduced = async (running: Introduced, sessionId: string): Promise<void> => {
  await waitFor(() => everyEndedTurn(running, sessionId) === 1)
  const index = running.agents.prompts.findIndex(([, input]) => isIntroduction(input))
  running.agents.prompts.splice(index, 1)
  introductionsOf(running).add(sessionId)
}

export const listBots = async (running: Running) =>
  decode(Schema.Array(Bot))((await jsonRequest(running.server, "/v1/bots")).body)

export const listProjects = async (running: Running) =>
  decode(Schema.Array(Project))((await jsonRequest(running.server, "/v1/projects")).body)
