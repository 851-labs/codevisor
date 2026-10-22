import { execFile } from "node:child_process"
import { mkdirSync, mkdtempSync, realpathSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import { Bot, decode, Project } from "@codevisor/api"
import { Schema } from "effect"
import { expect, onTestFinished } from "vitest"

import type { CodevisorServerConfig } from "../server.js"
import { jsonRequest, listSubjectEvents, start, tempDirs } from "../test-support.js"

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

export const setUp = async (configOverrides: Partial<CodevisorServerConfig> = {}) => {
  useWorktreesRoot()
  const running = await start(undefined, {}, configOverrides)
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

export const endedTurns = (running: Running, sessionId: string) =>
  listSubjectEvents(running.services, sessionId).filter(
    (event) =>
      event.kind === "session.updated" &&
      JSON.stringify(event.payload).includes('"turnState":"ended"')
  ).length

export const createBot = (running: Running, body: Record<string, unknown>) =>
  jsonRequest(running.server, "/v1/bots", {
    body: JSON.stringify({
      name: "Release Helper",
      symbolName: "sparkles",
      harnessId: "codex",
      ...body
    }),
    method: "POST"
  })

export const listBots = async (running: Running) =>
  decode(Schema.Array(Bot))((await jsonRequest(running.server, "/v1/bots")).body)

export const listProjects = async (running: Running) =>
  decode(Schema.Array(Project))((await jsonRequest(running.server, "/v1/projects")).body)
