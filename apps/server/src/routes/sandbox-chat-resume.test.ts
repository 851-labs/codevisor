import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"

import type { SessionSummary } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { tempDirs } from "../test-support.js"
import {
  readResumeFile,
  savedResumeOf,
  writeResumeFile,
  type ResumeHost
} from "./sandbox-chat-resume.js"

const tempHome = (): string => {
  const home = mkdtempSync(join(tmpdir(), "codevisor-resume-home-"))
  tempDirs.push(home)
  return home
}

const fileAt = (path: string, text: string): void => {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, text)
}

const chat = (fields: Partial<SessionSummary>): SessionSummary => ({
  id: "chat-1",
  projectId: "project-1",
  serverId: "server-a",
  harnessId: "claude-code",
  title: "Chat",
  origin: "codevisor",
  createdAt: "2026-11-16T00:00:00.000Z",
  ...fields
})

const signedOut = (home: string): ResumeHost => ({ auth: undefined, home })

const signedIn = (home: string, env: Record<string, string>): ResumeHost => {
  const account = { id: "account-1", profileKind: "managed" as const, env }
  return {
    home,
    auth: {
      accountContext: () => Promise.resolve(account),
      activeAccountContext: () => Promise.resolve(account)
    }
  }
}

const base64 = (text: string): string => Buffer.from(text).toString("base64")

describe("Claude's saved session", () => {
  it("is the session's own file and sub-agent files, read and written back in place", async () => {
    const before = tempHome()
    const projects = join(before, ".claude", "projects")
    fileAt(join(projects, "-repo", "abc.jsonl"), "main transcript")
    fileAt(join(projects, "-repo", "abc", "subagents", "agent-1.jsonl"), "sub-agent")
    fileAt(join(projects, "-repo", "other.jsonl"), "another chat")
    fileAt(join(projects, "-repo", "memory", "notes.md"), "memory")
    const session = chat({ agentSessionId: "abc" })

    const saved = await savedResumeOf(signedOut(before), session)
    const path = "-repo/abc.jsonl"
    const read = await readResumeFile(signedOut(before), session, { path, offset: 5, length: 64 })
    const after = tempHome()
    const write = { harnessId: "claude-code", path }
    await writeResumeFile(signedOut(after), { ...write, offset: 0, data: base64("main ") })
    await writeResumeFile(signedOut(after), { ...write, offset: 5, data: read.data })

    expect(saved).toEqual({
      agentSessionId: "abc",
      files: [
        { path: "-repo/abc.jsonl", sizeBytes: 15 },
        { path: "-repo/abc/subagents/agent-1.jsonl", sizeBytes: 9 }
      ]
    })
    expect(readFileSync(join(after, ".claude", "projects", path), "utf8")).toBe("main transcript")
  })

  it("isn't offered for a chat that never started, and other files can't be read or placed", async () => {
    const home = tempHome()
    fileAt(join(home, ".claude", "projects", "-repo", "other.jsonl"), "another chat")
    const session = chat({ agentSessionId: "abc" })
    const outside = { harnessId: "claude-code", path: "../../.ssh/config", offset: 0, data: "" }

    const unstarted = await savedResumeOf(signedOut(home), chat({ agentSessionId: "" }))
    const other = await readResumeFile(signedOut(home), session, {
      path: "-repo/other.jsonl",
      offset: 0,
      length: 64
    }).catch((cause: unknown) => cause)
    const escaped = await writeResumeFile(signedOut(home), outside).catch((cause: unknown) => cause)

    expect(unstarted).toBeUndefined()
    expect(String(other)).toContain("No saved agent session file: -repo/other.jsonl")
    expect(String(escaped)).toContain("can't place an agent session file at ../../.ssh/config")
  })
})

describe("Codex's saved session", () => {
  it("is the thread's rollout file in the chat's account, placed in the signed-in account", async () => {
    const before = tempHome()
    const path = "2026/11/16/rollout-2026-11-16T10-00-00-abc.jsonl"
    fileAt(join(before, "codex-home", "sessions", path), "rollout")
    fileAt(join(before, "codex-home", "sessions", "2026/11/16/rollout-x-other.jsonl"), "other")
    const session = chat({
      harnessId: "codex",
      agentSessionId: "abc",
      harnessAccountId: "account-1"
    })
    const host = signedIn(before, { CODEX_HOME: join(before, "codex-home") })
    const after = tempHome()

    const saved = await savedResumeOf(host, session)
    const read = await readResumeFile(host, session, { path, offset: 0, length: 64 })
    const placed = await writeResumeFile(signedIn(after, { CODEX_HOME: join(after, "home-2") }), {
      harnessId: "codex",
      path,
      offset: 0,
      data: read.data
    })

    expect(saved).toEqual({ agentSessionId: "abc", files: [{ path, sizeBytes: 7 }] })
    expect(placed).toEqual({ accountId: "account-1" })
    expect(readFileSync(join(after, "home-2", "sessions", path), "utf8")).toBe("rollout")
  })

  it("isn't saved or placed without a signed-in Codex account", async () => {
    const home = tempHome()
    const path = "2026/11/16/rollout-2026-11-16T10-00-00-abc.jsonl"
    fileAt(join(home, ".codex", "sessions", path), "rollout")
    const session = chat({ harnessId: "codex", agentSessionId: "abc" })
    const write = { harnessId: "codex", path, offset: 0, data: base64("rollout") }

    const saved = await savedResumeOf(signedOut(home), session)
    const refused = await writeResumeFile(signedOut(home), write).catch((cause: unknown) => cause)

    expect(saved).toBeUndefined()
    expect(String(refused)).toContain("codex isn't signed in on this sandbox yet")
  })
})
