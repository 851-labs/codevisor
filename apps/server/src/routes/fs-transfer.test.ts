import { execFile } from "node:child_process"
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import { describe, expect, it } from "vitest"

import { jsonRequest, start, tempDirs } from "../test-support.js"
import { keptBothCandidates } from "./fs-kept-both.js"

const run = promisify(execFile)

const tempRoot = (prefix: string): string => {
  const root = mkdtempSync(join(tmpdir(), prefix))
  tempDirs.push(root)
  return root
}

const upload = (
  baseUrl: string,
  path: string,
  body: string,
  conflict?: string
): Promise<Response> => {
  const query = new URLSearchParams({ path })
  if (conflict !== undefined) query.set("conflict", conflict)
  return fetch(`${baseUrl}/v1/fs/file?${query}`, { method: "PUT", body })
}

const names = (path: string, shape: "file" | "folder") =>
  [...keptBothCandidates(path, shape)].slice(0, 3)

describe("fs transfer routes", () => {
  it("names copies the way Finder does", () => {
    expect(names("/a/report.pdf", "file")).toEqual([
      "/a/report.pdf",
      "/a/report 2.pdf",
      "/a/report 3.pdf"
    ])
    expect(names("/a/.env", "file")).toEqual(["/a/.env", "/a/.env 2", "/a/.env 3"])
    expect(names("/a/my.site", "folder")).toEqual(["/a/my.site", "/a/my.site 2", "/a/my.site 3"])
  })

  it("uploads files beside existing ones, into new folders, or over them", async () => {
    const { server } = await start()
    const root = tempRoot("codevisor-fs-upload-")
    writeFileSync(join(root, "notes.txt"), "original")

    const kept = await upload(server.url, join(root, "notes.txt"), "dropped")
    expect(kept.status).toBe(201)
    expect(await kept.json()).toEqual({ path: join(root, "notes 2.txt") })
    expect(readFileSync(join(root, "notes.txt"), "utf8")).toBe("original")
    expect(readFileSync(join(root, "notes 2.txt"), "utf8")).toBe("dropped")

    const nested = await upload(
      server.url,
      join(root, "site", "assets", "logo.svg"),
      "<svg/>",
      "replace"
    )
    expect(await nested.json()).toEqual({ path: join(root, "site", "assets", "logo.svg") })

    const replaced = await upload(server.url, join(root, "notes.txt"), "newer", "replace")
    expect(replaced.status).toBe(201)
    expect(readFileSync(join(root, "notes.txt"), "utf8")).toBe("newer")
    expect(readdirSync(root).toSorted()).toEqual(["notes 2.txt", "notes.txt", "site"])
  })

  it("refuses uploads it can't place", async () => {
    const { server } = await start()
    const root = tempRoot("codevisor-fs-upload-refused-")
    writeFileSync(join(root, "plain"), "file")
    mkdirSync(join(root, "folder"))

    const underFile = await upload(server.url, join(root, "plain", "child.txt"), "x")
    expect(underFile.status).toBe(409)

    const overFolder = await upload(server.url, join(root, "folder"), "x", "replace")
    expect(overFolder.status).toBe(409)

    const badConflict = await upload(server.url, join(root, "a.txt"), "x", "merge")
    expect(badConflict.status).toBe(400)

    const relative = await upload(server.url, "relative.txt", "x")
    expect(relative.status).toBe(400)
    expect(readdirSync(root).toSorted()).toEqual(["folder", "plain"])
  })

  it("creates a uniquely named folder for a dropped folder", async () => {
    const { server } = await start()
    const root = tempRoot("codevisor-fs-mkdir-kept-")
    mkdirSync(join(root, "site"))
    const keepBoth = (path: string) =>
      jsonRequest(server, "/v1/fs/mkdir", {
        body: JSON.stringify({ path, conflict: "keepBoth" }),
        method: "POST"
      })

    expect((await keepBoth(join(root, "site"))).body).toEqual({ path: join(root, "site 2") })
    expect((await keepBoth(join(root, "fresh", "site"))).body).toEqual({
      path: join(root, "fresh", "site")
    })
  })

  it("streams a folder as a tar archive", async () => {
    const { server } = await start()
    const root = tempRoot("codevisor-fs-archive-")
    mkdirSync(join(root, "site", "assets"), { recursive: true })
    writeFileSync(join(root, "site", "index.html"), "<h1>hi</h1>")
    writeFileSync(join(root, "site", "assets", "app.js"), "run()")

    const response = await fetch(
      `${server.url}/v1/fs/archive?path=${encodeURIComponent(join(root, "site"))}`
    )
    expect(response.status).toBe(200)
    expect(response.headers.get("content-type")).toBe("application/x-tar")

    const archive = join(tempRoot("codevisor-fs-archive-out-"), "site.tar")
    writeFileSync(archive, Buffer.from(await response.arrayBuffer()))
    const extracted = tempRoot("codevisor-fs-archive-extract-")
    await run("tar", ["-x", "-f", archive, "-C", extracted])
    expect(readFileSync(join(extracted, "site", "index.html"), "utf8")).toBe("<h1>hi</h1>")
    expect(readFileSync(join(extracted, "site", "assets", "app.js"), "utf8")).toBe("run()")

    const missing = await fetch(
      `${server.url}/v1/fs/archive?path=${encodeURIComponent(join(root, "gone"))}`
    )
    expect(missing.status).toBe(404)
  })
})
