import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  writeFileSync
} from "node:fs"
import { homedir, tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it } from "vitest"

import { jsonRequest, start, tempDirs } from "../test-support.js"

const tempRoot = (prefix: string): string => {
  const root = mkdtempSync(join(tmpdir(), prefix))
  tempDirs.push(root)
  return root
}

const post = (server: Awaited<ReturnType<typeof start>>["server"], path: string, body: unknown) =>
  jsonRequest(server, path, { body: JSON.stringify(body), method: "POST" })

describe("fs edit routes", () => {
  it("renames files without replacing what's already there", async () => {
    const { server } = await start()
    const root = tempRoot("codevisor-fs-move-")
    writeFileSync(join(root, "draft.md"), "draft")
    writeFileSync(join(root, "taken.md"), "keep me")

    const renamed = await post(server, "/v1/fs/move", {
      from: join(root, "draft.md"),
      to: join(root, "final.md")
    })
    expect(renamed.body).toEqual({ path: join(root, "final.md") })
    expect(readFileSync(join(root, "final.md"), "utf8")).toBe("draft")

    const clash = await post(server, "/v1/fs/move", {
      from: join(root, "final.md"),
      to: join(root, "taken.md")
    })
    expect(clash.status).toBe(409)
    expect(readFileSync(join(root, "taken.md"), "utf8")).toBe("keep me")

    const missing = await post(server, "/v1/fs/move", {
      from: join(root, "gone.md"),
      to: join(root, "other.md")
    })
    expect(missing.status).toBe(404)
  })

  it("deletes files and folders but never a root or home folder", async () => {
    const { server } = await start()
    const root = tempRoot("codevisor-fs-delete-")
    mkdirSync(join(root, "build", "cache"), { recursive: true })
    writeFileSync(join(root, "build", "cache", "a.bin"), "x")
    writeFileSync(join(root, "notes.txt"), "x")
    writeFileSync(join(root, "keep.txt"), "x")

    const deleted = await post(server, "/v1/fs/delete", {
      paths: [join(root, "build"), join(root, "notes.txt"), join(root, "already-gone")]
    })
    expect(deleted.status).toBe(200)
    expect(readdirSync(root)).toEqual(["keep.txt"])

    expect((await post(server, "/v1/fs/delete", { paths: ["/"] })).status).toBe(400)
    expect((await post(server, "/v1/fs/delete", { paths: [homedir()] })).status).toBe(400)
    expect(existsSync(join(root, "keep.txt"))).toBe(true)
  })
})
