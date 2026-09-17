import { mkdir, mkdtemp, opendir, rm, symlink, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, expect, it, vi } from "vitest"

import { searchFileEntries } from "./file-search.js"

vi.mock("node:fs/promises", async (original) => {
  const actual = await original<typeof import("node:fs/promises")>()
  return { ...actual, opendir: vi.fn(actual.opendir) }
})
afterEach(() => vi.resetAllMocks())

it("finds nested, hidden, and duplicate filenames without following directory symlinks", async () => {
  const root = await mkdtemp(join(tmpdir(), "codevisor-file-search-"))
  try {
    await mkdir(join(root, "Configuration", ".local"), { recursive: true })
    await writeFile(join(root, "Configuration", "settings.json"), "{}")
    await writeFile(join(root, "Configuration", ".local", "settings.json"), "{}")
    await writeFile(join(root, ".settings.json"), "{}")
    await symlink(root, join(root, "cycle"))
    await symlink(join(root, "missing"), join(root, "settings-broken"))
    await symlink(join(root, "Configuration", "settings.json"), join(root, "settings-link"))
    const result = await searchFileEntries(root, "SETTINGS")
    expect(result.entries.map((entry) => entry.path).toSorted()).toEqual(
      [
        join(root, ".settings.json"),
        join(root, "Configuration", ".local", "settings.json"),
        join(root, "Configuration", "settings.json"),
        join(root, "settings-link")
      ].toSorted()
    )
    expect(result.truncated).toBe(false)
    expect(result.skippedDirectories).toBe(0)
    expect((await searchFileEntries(root, "configuration/.local/settings")).entries).toHaveLength(1)
    expect((await searchFileEntries(root, "no-match")).entries).toEqual([])
    expect((await searchFileEntries(root, "cycle")).entries).toEqual([])
    expect((await searchFileEntries(root, "")).entries).toEqual([])
    await rm(join(root, "Configuration", "settings.json"))
    expect((await searchFileEntries(root, "settings")).entries).toHaveLength(2)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

it("reports unreadable children but fails if the search root itself cannot be read", async () => {
  const root = await mkdtemp(join(tmpdir(), "codevisor-file-search-permissions-"))
  try {
    await mkdir(join(root, "unreadable"))
    const denied = Object.assign(new Error("permission denied"), { code: "EACCES" })
    const actual = await vi.importActual<typeof import("node:fs/promises")>("node:fs/promises")
    vi.mocked(opendir).mockImplementationOnce(actual.opendir).mockRejectedValueOnce(denied)
    expect(await searchFileEntries(root, "file")).toMatchObject({
      entries: [],
      skippedDirectories: 1,
      truncated: false
    })
    vi.mocked(opendir).mockRejectedValueOnce(denied)
    await expect(searchFileEntries(root, "file")).rejects.toBe(denied)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

it("reports incomplete searches and honors cancellation", async () => {
  const root = await mkdtemp(join(tmpdir(), "codevisor-file-search-limit-"))
  try {
    await writeFile(join(root, "one.txt"), "")
    await writeFile(join(root, "two.txt"), "")
    const limited = await searchFileEntries(root, ".txt", { maxResults: 1 })
    expect(limited.entries).toHaveLength(1)
    expect(limited.truncated).toBe(true)
    expect((await searchFileEntries(root, "missing", { maxEntries: 1 })).truncated).toBe(true)
    await expect(
      searchFileEntries(root, "txt", { signal: AbortSignal.abort() })
    ).rejects.toBeDefined()
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})
