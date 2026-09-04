import { lstat, mkdir, mkdtemp, readFile, realpath, rm, utimes, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import {
  defaultClaudeConfigPath,
  ensureSharedClaudeConversations
} from "./claude-conversation-storage.js"

const directories: string[] = []

afterEach(async () => {
  await Promise.all(
    directories.splice(0).map((directory) => rm(directory, { force: true, recursive: true }))
  )
})

describe("shared Claude conversation storage", () => {
  it("migrates the newest histories and shares subsequent writes", async () => {
    const directory = await mkdtemp(join(tmpdir(), "codevisor-claude-conversations-"))
    directories.push(directory)
    const defaultConfig = join(directory, ".claude")
    const firstProfile = join(directory, "managed-a")
    const secondProfile = join(directory, "managed-b")
    const project = "-tmp-project"
    const session = "11111111-1111-4111-8111-111111111111.jsonl"
    const defaultThread = join(defaultConfig, "projects", project, session)
    const firstThread = join(firstProfile, "projects", project, session)
    const secondThread = join(secondProfile, "projects", project, session)
    await Promise.all([
      mkdir(join(defaultConfig, "projects", project), { recursive: true }),
      mkdir(join(firstProfile, "projects", project, "tool-results"), { recursive: true }),
      mkdir(join(secondProfile, "projects", project), { recursive: true })
    ])
    await Promise.all([
      writeFile(defaultThread, "default history\n"),
      writeFile(firstThread, "newest history\n"),
      writeFile(secondThread, "middle history\n"),
      writeFile(
        join(firstProfile, "projects", project, "tool-results", "result.txt"),
        "tool result\n"
      )
    ])
    await Promise.all([
      utimes(defaultThread, new Date(1_000), new Date(1_000)),
      utimes(firstThread, new Date(3_000), new Date(3_000)),
      utimes(secondThread, new Date(2_000), new Date(2_000))
    ])

    await ensureSharedClaudeConversations(defaultConfig, [secondProfile, firstProfile])

    const sharedProjects = await realpath(join(defaultConfig, "projects"))
    await expect(realpath(join(firstProfile, "projects"))).resolves.toBe(sharedProjects)
    await expect(realpath(join(secondProfile, "projects"))).resolves.toBe(sharedProjects)
    expect((await lstat(join(firstProfile, "projects"))).isSymbolicLink()).toBe(true)
    await expect(readFile(defaultThread, "utf8")).resolves.toBe("newest history\n")
    await expect(
      readFile(join(defaultConfig, "projects", project, "tool-results", "result.txt"), "utf8")
    ).resolves.toBe("tool result\n")

    const sharedWrite = join(firstProfile, "projects", project, "shared.txt")
    await writeFile(sharedWrite, "visible everywhere\n")
    await expect(
      readFile(join(secondProfile, "projects", project, "shared.txt"), "utf8")
    ).resolves.toBe("visible everywhere\n")

    await ensureSharedClaudeConversations(defaultConfig, [firstProfile, secondProfile])
    await rm(firstProfile, { force: true, recursive: true })
    await expect(
      readFile(join(defaultConfig, "projects", project, "shared.txt"), "utf8")
    ).resolves.toBe("visible everywhere\n")
  })

  it("uses an explicit Claude config directory for the canonical history", () => {
    expect(
      defaultClaudeConfigPath({
        CLAUDE_CONFIG_DIR: "/tmp/custom-claude",
        HOME: "/tmp/home"
      })
    ).toBe("/tmp/custom-claude")
  })
})
