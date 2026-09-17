import {
  chmodSync,
  mkdtempSync,
  readFileSync,
  realpathSync,
  lstatSync,
  statSync,
  symlinkSync,
  writeFileSync
} from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { start, tempDirs } from "../test-support.js"

describe("file documents", () => {
  it("reads text, preserves bytes and permissions, and rejects stale saves", async () => {
    const { server } = await start()
    const root = realpathSync(mkdtempSync(join(tmpdir(), "codevisor-documents-")))
    tempDirs.push(root)
    const path = join(root, "example.ts")
    writeFileSync(path, "const café = 1\r\n", { mode: 0o755 })
    const endpoint = `${server.url}/v1/fs/document?path=${encodeURIComponent(path)}`
    const original = await (await fetch(endpoint)).json()
    expect(original).toMatchObject({ path, content: "const café = 1\r\n", writable: true })
    const save = (content: string, version: string) =>
      fetch(endpoint, {
        method: "PUT",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ content, version })
      })
    const saved = await save("const café = 2\r\n", original.version)
    expect(saved.status).toBe(200)
    expect(readFileSync(path, "utf8")).toBe("const café = 2\r\n")
    expect(statSync(path).mode & 0o777).toBe(0o755)
    const stale = await save("stale contents", original.version)
    expect(stale.status).toBe(409)
    expect(await stale.json()).toMatchObject({ code: "file_conflict" })
    expect(readFileSync(path, "utf8")).toBe("const café = 2\r\n")
    const latest = await saved.json()
    writeFileSync(path, "changed by agent")
    expect((await save("my edits", latest.version)).status).toBe(409)
    expect(readFileSync(path, "utf8")).toBe("changed by agent")
  })

  it("lists files and resolves symlinks without replacing them when saving", async () => {
    const { server } = await start()
    const root = realpathSync(mkdtempSync(join(tmpdir(), "codevisor-document-links-")))
    tempDirs.push(root)
    const path = join(root, "notes.md")
    const link = join(root, "linked.md")
    writeFileSync(path, "# Notes")
    writeFileSync(join(root, ".hidden"), "hidden")
    symlinkSync(path, link)
    const listing = await (
      await fetch(`${server.url}/v1/fs/entries?path=${encodeURIComponent(root)}`)
    ).json()
    expect(listing.entries.map((entry: { name: string }) => entry.name)).toEqual([
      "linked.md",
      "notes.md"
    ])
    const endpoint = `${server.url}/v1/fs/document?path=${encodeURIComponent(link)}`
    const original = await (await fetch(endpoint)).json()
    expect(original.path).toBe(path)
    const response = await fetch(endpoint, {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ content: "# Updated", version: original.version })
    })
    expect(response.status).toBe(200)
    expect(readFileSync(path, "utf8")).toBe("# Updated")
    expect(readFileSync(link, "utf8")).toBe("# Updated")
    expect(lstatSync(link).isSymbolicLink()).toBe(true)
  })

  it("protects binary and read-only files and reports missing paths", async () => {
    const { server } = await start()
    const root = mkdtempSync(join(tmpdir(), "codevisor-document-formats-"))
    tempDirs.push(root)
    const path = join(root, "binary.dat")
    writeFileSync(path, Buffer.from([0, 255, 1]))
    const endpoint = `${server.url}/v1/fs/document?path=${encodeURIComponent(path)}`
    const binary = await (await fetch(endpoint)).json()
    expect(binary).toMatchObject({ content: null, writable: false, size: 3 })
    const rejected = await fetch(endpoint, {
      method: "PUT",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ content: "oops", version: binary.version })
    })
    expect(rejected.status).toBe(403)
    writeFileSync(path, "read only")
    chmodSync(path, 0o444)
    try {
      expect(await (await fetch(endpoint)).json()).toMatchObject({ writable: false })
    } finally {
      chmodSync(path, 0o644)
    }
    expect(
      (
        await fetch(
          `${server.url}/v1/fs/document?path=${encodeURIComponent(join(root, "missing"))}`
        )
      ).status
    ).toBe(404)
    expect((await fetch(`${server.url}/v1/fs/document?path=relative`)).status).toBe(400)
  })
})
