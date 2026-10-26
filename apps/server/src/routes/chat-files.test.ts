import { execFile } from "node:child_process"
import { randomUUID } from "node:crypto"
import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { promisify } from "node:util"

import { decode, Worktree } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { archiveJobs } from "../archive-jobs.js"
import { makeEventFanout } from "../server.js"
import { jsonRequest, run, start, tempDirs } from "../test-support.js"
import { field, idOf } from "./response-test-support.js"
import { sessionEventSink } from "./session-events.js"

const execFileAsync = promisify(execFile)
const git = (args: ReadonlyArray<string>, cwd: string) =>
  execFileAsync("git", ["-c", "user.email=t@t", "-c", "user.name=t", ...args], { cwd })

const withWorktreesRoot = async <A>(body: () => Promise<A>): Promise<A> => {
  const worktreesRoot = mkdtempSync(join(tmpdir(), "codevisor-chat-files-worktrees-"))
  tempDirs.push(worktreesRoot)
  process.env["CODEVISOR_WORKTREES_ROOT"] = worktreesRoot
  try {
    return await body()
  } finally {
    delete process.env["CODEVISOR_WORKTREES_ROOT"]
  }
}

const chatInWorktree = async () => {
  const running = await start()
  const repo = join(mkdtempSync(join(tmpdir(), "codevisor-chat-files-repo-")), "repo")
  tempDirs.push(repo)
  mkdirSync(repo)
  await git(["init"], repo)
  await git(["commit", "--allow-empty", "-m", "init"], repo)
  await jsonRequest(running.server, "/v1/projects", {
    body: JSON.stringify({ folderPath: repo, id: "chat-files" }),
    method: "POST"
  })
  const tree = decode(Worktree)(
    (
      await jsonRequest(running.server, "/v1/projects/chat-files/worktrees", {
        body: JSON.stringify({ name: "chat files" }),
        method: "POST"
      })
    ).body
  )
  const workspaceId = randomUUID()
  const chatId = idOf(
    (
      await jsonRequest(running.server, "/v1/sessions", {
        body: JSON.stringify({
          projectId: "chat-files",
          workspaceId,
          harnessId: "codex",
          worktreeName: tree.name
        }),
        method: "POST"
      })
    ).body
  )
  return { ...running, tree, workspaceId, chatId }
}

const writeFile = (path: string, contents: string): void => {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, contents)
}

const text = (value: string) => ({
  sessionUpdate: "agent_message_chunk",
  content: { type: "text", text: value }
})

const storedFileIds = (texts: ReadonlyArray<string>): ReadonlyArray<string> =>
  texts.flatMap((value) =>
    [...value.matchAll(/attachments\.codevisor\.invalid\/([A-Za-z0-9-]+)/g)].map(
      (match) => match[1]!
    )
  )

describe("chat files", () => {
  it("keeps files linked between tool calls and in the reply after the worktree is archived", async () => {
    await withWorktreesRoot(async () => {
      const { server, services, tree, workspaceId, chatId } = await chatInWorktree()
      writeFile(join(tree.path, ".gitignore"), "build/\n")
      writeFile(join(tree.path, "build", "shot.png"), "pixels")
      writeFile(join(tree.path, "notes", "report.pdf"), "%PDF report")
      const fanout = await run(makeEventFanout)
      const patches: Array<string> = []
      fanout.subscribe((event) => {
        const patched = field(event.payload, "text")
        if (typeof patched === "string") patches.push(patched)
      })
      const sink = sessionEventSink(services, fanout, "server-a", chatId)
      const output = (payload: Record<string, unknown>) =>
        sink({ kind: "session.output", subjectId: chatId, payload })
      await sink({
        kind: "session.updated",
        subjectId: chatId,
        payload: { initiatedBy: "user", turnId: "turn-1", turnState: "started" }
      })
      await output(text("Before the check: ![Shot](build/shot.png)"))
      await output({
        sessionUpdate: "tool_call",
        toolCallId: "check",
        title: "Run",
        kind: "execute"
      })

      const [shotId] = storedFileIds(patches)
      expect(patches.at(-1)).toBe(
        `Before the check: ![Shot](https://attachments.codevisor.invalid/${shotId})`
      )

      await output(text(`Done: [Report](${join(tree.path, "notes", "report.pdf")})`))
      await sink({
        kind: "session.updated",
        subjectId: chatId,
        payload: { initiatedBy: "user", turnId: "turn-1", turnState: "ended" }
      })
      await jsonRequest(server, `/v1/workspaces/${workspaceId}`, {
        body: JSON.stringify({ isArchived: true }),
        method: "PATCH"
      })
      await archiveJobs(services).idle()

      expect(existsSync(tree.path)).toBe(false)
      const page = await run(services.db.getTranscriptPage(chatId, undefined, 8))
      expect(page.items.find((item) => item.role === "assistant")?.text).not.toContain(tree.path)
      const stored = await Promise.all(
        [...new Set(storedFileIds(patches))].map(async (fileId) => {
          const response = await fetch(`${server.url}/v1/files/${fileId}`)
          return response.text()
        })
      )
      expect(stored).toEqual(["pixels", "%PDF report"])
    })
  })
})
