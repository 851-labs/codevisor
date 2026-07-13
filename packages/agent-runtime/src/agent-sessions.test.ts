import { mkdtempSync, mkdirSync, rmSync, utimesSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterAll, describe, expect, it } from "vitest"
import {
  defaultAgentSessionFileSystem,
  listClaudeAgentSessions,
  listCodexAgentSessions,
  type AgentSessionFileSystem
} from "./agent-sessions.js"

/// A fake store: absolute path → file body (directories are implied).
const makeFakeFs = (
  files: Record<string, string>,
  existingDirectories: ReadonlyArray<string>,
  mtimes: Record<string, number> = {}
): AgentSessionFileSystem => {
  const directories = new Set<string>(existingDirectories)
  for (const path of Object.keys(files)) {
    const parts = path.split("/")
    for (let index = 1; index < parts.length; index += 1) {
      directories.add(parts.slice(0, index).join("/") || "/")
    }
  }
  return {
    listDirectory: (path) => {
      const names = new Set<string>()
      const prefix = `${path}/`
      for (const candidate of [...Object.keys(files), ...directories]) {
        if (candidate.startsWith(prefix)) {
          const name = candidate.slice(prefix.length).split("/", 1)[0] as string
          if (name.length > 0) names.add(name)
        }
      }
      return Promise.resolve([...names])
    },
    statFile: (path) => {
      if (files[path] !== undefined) {
        return Promise.resolve({ mtimeMs: mtimes[path] ?? 1_000, isDirectory: false })
      }
      if (directories.has(path)) {
        return Promise.resolve({ mtimeMs: 0, isDirectory: true })
      }
      return Promise.resolve(undefined)
    },
    readHead: (path, maxBytes) => {
      const body = files[path]
      return Promise.resolve(body === undefined ? undefined : body.slice(0, maxBytes))
    },
    directoryExists: (path) => Promise.resolve(directories.has(path))
  }
}

const claudeLine = (entry: Record<string, unknown>): string => JSON.stringify(entry)

describe("listClaudeAgentSessions", () => {
  const home = "/home/tester"
  const projects = `${home}/.claude/projects`

  it("lists sessions newest-first with cwd, title, and file-name session id", async () => {
    const fs = makeFakeFs(
      {
        [`${projects}/-repo-a/older.jsonl`]: [
          claudeLine({ type: "queue-operation", operation: "enqueue" }),
          claudeLine({
            type: "user",
            cwd: "/repo/a",
            message: { role: "user", content: [{ type: "text", text: "First question\nmore" }] }
          })
        ].join("\n"),
        [`${projects}/-repo-b/newer.jsonl`]: [
          claudeLine({ type: "user", isMeta: true, cwd: "/repo/b", message: { content: "meta" } }),
          claudeLine({ type: "user", message: { content: "String content form" } }),
          claudeLine({ type: "assistant", message: { content: [] } })
        ].join("\n"),
        [`${projects}/-repo-b/notes.txt`]: "not a session"
      },
      ["/repo/a", "/repo/b"],
      { [`${projects}/-repo-a/older.jsonl`]: 1_000, [`${projects}/-repo-b/newer.jsonl`]: 2_000 }
    )

    const sessions = await listClaudeAgentSessions({ homedir: home, fs })

    expect(sessions.map((session) => session.sessionId)).toEqual(["newer", "older"])
    expect(sessions[0]).toMatchObject({
      cwd: "/repo/b",
      title: "String content form",
      updatedAt: new Date(2_000).toISOString()
    })
    expect(sessions[1]).toMatchObject({ cwd: "/repo/a", title: "First question" })
  })

  it("caps at the limit by recency before reading any file bodies", async () => {
    const files: Record<string, string> = {}
    const mtimes: Record<string, number> = {}
    for (let index = 0; index < 5; index += 1) {
      const path = `${projects}/-x/session-${index}.jsonl`
      files[path] = claudeLine({ type: "user", cwd: "/x", message: { content: "hi" } })
      mtimes[path] = index
    }
    const fs = makeFakeFs(files, ["/x"], mtimes)

    const sessions = await listClaudeAgentSessions({ homedir: home, fs, limit: 2 })

    expect(sessions.map((session) => session.sessionId)).toEqual(["session-4", "session-3"])
  })

  it("skips deleted cwds, cwd-less files, unreadable heads, and unparseable lines", async () => {
    const base: AgentSessionFileSystem = makeFakeFs(
      {
        [`${projects}/-gone/gone.jsonl`]: claudeLine({
          type: "user",
          cwd: "/deleted/repo",
          message: { content: "hello" }
        }),
        [`${projects}/-junk/junk.jsonl`]: "not json\n42\n",
        [`${projects}/-unreadable/locked.jsonl`]: claudeLine({ cwd: "/x" })
      },
      ["/x"]
    )
    const fs: AgentSessionFileSystem = {
      ...base,
      readHead: (path, maxBytes) =>
        path.endsWith("locked.jsonl") ? Promise.resolve(undefined) : base.readHead(path, maxBytes)
    }

    await expect(listClaudeAgentSessions({ homedir: home, fs })).resolves.toEqual([])
  })

  it("handles empty titles, truncation, and messages without text blocks", async () => {
    const longLine = "x".repeat(120)
    const fs = makeFakeFs(
      {
        [`${projects}/-a/one.jsonl`]: [
          claudeLine({ type: "user", cwd: "/a", message: { content: [{ type: "tool_result" }] } }),
          claudeLine({ type: "user", message: {} }),
          claudeLine({
            type: "user",
            message: { content: [{ type: "text", text: `  ${longLine}` }] }
          })
        ].join("\n")
      },
      ["/a"]
    )

    const sessions = await listClaudeAgentSessions({ homedir: home, fs })

    expect(sessions).toHaveLength(1)
    expect(sessions[0]?.title).toHaveLength(80)
    expect(sessions[0]?.title?.endsWith("…")).toBe(true)
  })

  it("returns [] when the projects root is missing and skips unstattable files", async () => {
    await expect(
      listClaudeAgentSessions({ homedir: home, fs: makeFakeFs({}, []) })
    ).resolves.toEqual([])

    const base = makeFakeFs({ [`${projects}/-a/ghost.jsonl`]: claudeLine({ cwd: "/a" }) }, ["/a"])
    const fs: AgentSessionFileSystem = { ...base, statFile: () => Promise.resolve(undefined) }
    await expect(listClaudeAgentSessions({ homedir: home, fs })).resolves.toEqual([])
  })

  it("lists a session without any user message as title-less", async () => {
    const fs = makeFakeFs(
      { [`${projects}/-a/quiet.jsonl`]: claudeLine({ type: "system", cwd: "/a" }) },
      ["/a"]
    )
    const sessions = await listClaudeAgentSessions({ homedir: home, fs })
    expect(sessions).toHaveLength(1)
    expect(sessions[0]?.title).toBeUndefined()
  })

  it("defaults the home directory when none is given", async () => {
    // A fake fs sees no files under the real home's store paths — the point
    // is exercising the os.homedir() default without touching real files.
    await expect(listClaudeAgentSessions({ fs: makeFakeFs({}, []) })).resolves.toEqual([])
    await expect(listCodexAgentSessions({ fs: makeFakeFs({}, []) })).resolves.toEqual([])
  })
})

describe("listCodexAgentSessions", () => {
  const home = "/home/tester"
  const root = `${home}/.codex/sessions`

  const metaLine = (id: string, cwd: string): string =>
    JSON.stringify({ type: "session_meta", payload: { id, cwd, timestamp: "t" } })
  const userLine = (message: string): string =>
    JSON.stringify({ type: "event_msg", payload: { type: "user_message", message } })

  it("lists rollouts with meta id/cwd and first user-message title", async () => {
    const fs = makeFakeFs(
      {
        [`${root}/2026/07/01/rollout-a.jsonl`]: [
          metaLine("codex-1", "/repo/one"),
          metaLine("codex-shadowed", "/repo/ignored"),
          JSON.stringify({ type: "event_msg", payload: { type: "agent_message" } }),
          JSON.stringify({ type: "event_msg" }),
          userLine("Fix the tests")
        ].join("\n"),
        [`${root}/2026/07/02/rollout-b.jsonl`]: metaLine("codex-2", "/repo/two"),
        [`${root}/2026/07/02/notes.jsonl`]: metaLine("not-a-rollout", "/repo/two")
      },
      ["/repo/one", "/repo/two"],
      {
        [`${root}/2026/07/01/rollout-a.jsonl`]: 2_000,
        [`${root}/2026/07/02/rollout-b.jsonl`]: 1_000
      }
    )

    const sessions = await listCodexAgentSessions({ homedir: home, fs })

    expect(sessions).toEqual([
      {
        sessionId: "codex-1",
        cwd: "/repo/one",
        title: "Fix the tests",
        updatedAt: new Date(2_000).toISOString()
      },
      { sessionId: "codex-2", cwd: "/repo/two", updatedAt: new Date(1_000).toISOString() }
    ])
  })

  it("skips rollouts without usable meta, deleted cwds, unreadable heads, and deep nesting", async () => {
    const base = makeFakeFs(
      {
        [`${root}/a/rollout-nometa.jsonl`]: userLine("no meta here"),
        [`${root}/a/rollout-badmeta.jsonl`]: JSON.stringify({
          type: "session_meta",
          payload: { id: 42 }
        }),
        [`${root}/a/rollout-nopayload.jsonl`]: `garbage line\n${JSON.stringify({ type: "session_meta" })}`,
        [`${root}/a/rollout-gone.jsonl`]: metaLine("x", "/deleted"),
        [`${root}/a/rollout-locked.jsonl`]: metaLine("y", "/ok"),
        [`${root}/a/rollout-unstattable.jsonl`]: metaLine("z", "/ok"),
        // Below the depth bound — never reached by the walk.
        [`${root}/1/2/3/4/5/rollout-deep.jsonl`]: metaLine("deep", "/ok")
      },
      ["/ok"]
    )
    const fs: AgentSessionFileSystem = {
      ...base,
      readHead: (path, maxBytes) =>
        path.endsWith("locked.jsonl") ? Promise.resolve(undefined) : base.readHead(path, maxBytes),
      statFile: (path) =>
        path.endsWith("rollout-unstattable.jsonl")
          ? Promise.resolve(undefined)
          : base.statFile(path)
    }

    await expect(listCodexAgentSessions({ homedir: home, fs })).resolves.toEqual([])
  })

  it("keeps scanning for meta after the title arrives first", async () => {
    const fs = makeFakeFs(
      {
        [`${root}/a/rollout-titlefirst.jsonl`]: [
          userLine("Title before meta"),
          userLine("Second message ignored"),
          metaLine("late-meta", "/ok")
        ].join("\n")
      },
      ["/ok"]
    )
    await expect(listCodexAgentSessions({ homedir: home, fs })).resolves.toEqual([
      {
        sessionId: "late-meta",
        cwd: "/ok",
        title: "Title before meta",
        updatedAt: new Date(1_000).toISOString()
      }
    ])
  })

  it("returns [] for a missing sessions root", async () => {
    await expect(
      listCodexAgentSessions({ homedir: home, fs: makeFakeFs({}, []) })
    ).resolves.toEqual([])
  })
})

describe("defaultAgentSessionFileSystem", () => {
  const scratch = mkdtempSync(join(tmpdir(), "codevisor-agent-sessions-"))
  afterAll(() => rmSync(scratch, { recursive: true, force: true }))

  it("reads real directories, stats, heads, and existence", async () => {
    const dir = join(scratch, "store")
    mkdirSync(dir, { recursive: true })
    const file = join(dir, "session.jsonl")
    writeFileSync(file, "PAYLOAD-LINE\nsecond line\n")
    utimesSync(file, new Date(1_700_000_000_000), new Date(1_700_000_000_000))

    await expect(defaultAgentSessionFileSystem.listDirectory(dir)).resolves.toEqual([
      "session.jsonl"
    ])
    await expect(defaultAgentSessionFileSystem.listDirectory(join(dir, "nope"))).resolves.toEqual(
      []
    )

    const stat = await defaultAgentSessionFileSystem.statFile(file)
    expect(stat?.isDirectory).toBe(false)
    expect(stat?.mtimeMs).toBe(1_700_000_000_000)
    await expect(defaultAgentSessionFileSystem.statFile(join(dir, "nope"))).resolves.toBeUndefined()

    await expect(defaultAgentSessionFileSystem.readHead(file, 7)).resolves.toBe("PAYLOAD")
    await expect(
      defaultAgentSessionFileSystem.readHead(join(dir, "nope"), 7)
    ).resolves.toBeUndefined()

    await expect(defaultAgentSessionFileSystem.directoryExists(dir)).resolves.toBe(true)
    await expect(defaultAgentSessionFileSystem.directoryExists(file)).resolves.toBe(false)
    await expect(defaultAgentSessionFileSystem.directoryExists(join(dir, "nope"))).resolves.toBe(
      false
    )
  })

  it("backs the scanners end-to-end against a real store layout", async () => {
    const home = join(scratch, "home")
    const projectDir = join(home, ".claude", "projects", "-real-repo")
    mkdirSync(projectDir, { recursive: true })
    const workspace = join(scratch, "workspace")
    mkdirSync(workspace)
    writeFileSync(
      join(projectDir, "abc.jsonl"),
      `${JSON.stringify({ type: "user", cwd: workspace, message: { content: "Real question" } })}\n`
    )

    const sessions = await listClaudeAgentSessions({ homedir: home })
    expect(sessions).toEqual([
      {
        sessionId: "abc",
        cwd: workspace,
        title: "Real question",
        updatedAt: expect.any(String)
      }
    ])

    // No ~/.codex at all under this home.
    await expect(listCodexAgentSessions({ homedir: home })).resolves.toEqual([])
  })
})
