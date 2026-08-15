import { randomUUID } from "node:crypto"
import { chmodSync, mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { pathToFileURL } from "node:url"
import { describe, expect, it } from "vitest"
import { jsonRequest, start, tempDirs } from "../test-support.js"

describe("fs routes", () => {
  it("lists directories for the remote project picker", async () => {
    const { server } = await start()
    const root = mkdtempSync(join(tmpdir(), "codevisor-fs-"))
    tempDirs.push(root)
    mkdirSync(join(root, "beta"))
    mkdirSync(join(root, "Alpha", ".git"), { recursive: true })
    mkdirSync(join(root, ".hidden"))
    writeFileSync(join(root, "file.txt"), "not a directory")

    const listing = await jsonRequest(server, `/v1/fs/list?path=${encodeURIComponent(root)}`)
    expect(listing.status).toBe(200)
    expect(listing.body).toMatchObject({
      path: root,
      parent: dirname(root),
      entries: [
        { name: "Alpha", path: join(root, "Alpha"), isGitRepo: true },
        { name: "beta", path: join(root, "beta"), isGitRepo: false }
      ]
    })

    const withHidden = await jsonRequest(
      server,
      `/v1/fs/list?path=${encodeURIComponent(root)}&showHidden=true`
    )
    expect((withHidden.body as { entries: Array<{ name: string }> }).entries[0]?.name).toBe(
      ".hidden"
    )

    // Home expansion: bare "~" and "~/..." resolve against the server's home.
    const home = await jsonRequest(server, "/v1/fs/list")
    expect(home.status).toBe(200)
    expect((home.body as { path: string }).path.startsWith("/")).toBe(true)

    // The filesystem root has no parent.
    const rootListing = await jsonRequest(server, "/v1/fs/list?path=/")
    expect((rootListing.body as { parent: string | null }).parent).toBeNull()

    // "~/…" paths expand under the server's home.
    const homeChild = await jsonRequest(server, "/v1/fs/list?path=%7E%2F")
    expect(homeChild.status).toBe(200)

    const missing = await jsonRequest(
      server,
      `/v1/fs/list?path=${encodeURIComponent(join(root, "nope"))}`
    )
    expect(missing.status).toBe(404)
    expect(missing.body).toMatchObject({ code: "not_found" })

    const notDir = await jsonRequest(
      server,
      `/v1/fs/list?path=${encodeURIComponent(join(root, "file.txt"))}`
    )
    expect(notDir.status).toBe(400)
    expect(notDir.body).toMatchObject({ code: "not_a_directory" })

    const relative = await jsonRequest(server, "/v1/fs/list?path=relative/path")
    expect(relative.status).toBe(400)
    expect(relative.body).toMatchObject({ code: "invalid_path" })

    // Symlinks: follow directory links, skip broken ones and plain files.
    const linked = mkdtempSync(join(tmpdir(), "codevisor-fs-links-"))
    tempDirs.push(linked)
    symlinkSync(join(root, "beta"), join(linked, "beta-link"))
    symlinkSync(join(root, "gone"), join(linked, "broken-link"))
    symlinkSync(join(root, "file.txt"), join(linked, "file-link"))
    const links = await jsonRequest(server, `/v1/fs/list?path=${encodeURIComponent(linked)}`)
    expect((links.body as { entries: Array<{ name: string }> }).entries.map((e) => e.name)).toEqual(
      ["beta-link"]
    )

    // Unreadable directories surface a permission error, not a crash.
    const sealed = join(root, "sealed")
    mkdirSync(sealed, { mode: 0o000 })
    const denied = await jsonRequest(server, `/v1/fs/list?path=${encodeURIComponent(sealed)}`)
    chmodSync(sealed, 0o755)
    expect(denied.status).toBe(403)
    expect(denied.body).toMatchObject({ code: "permission_denied" })
  })

  it("streams live filesystem files by absolute or session-relative path", async () => {
    const { server } = await start()
    const root = mkdtempSync(join(tmpdir(), "codevisor-fs-file-"))
    tempDirs.push(root)
    const path = join(root, "report 2026.pdf")
    const bytes = Buffer.from("0123456789")
    writeFileSync(path, bytes)

    const absolute = await fetch(`${server.url}/v1/fs/file?path=${encodeURIComponent(path)}`)
    expect(absolute.status).toBe(200)
    expect(absolute.headers.get("content-type")).toBe("application/pdf")
    expect(absolute.headers.get("cache-control")).toBe("private, no-store")
    expect(Buffer.from(await absolute.arrayBuffer())).toEqual(bytes)

    const fileURL = await fetch(
      `${server.url}/v1/fs/file?path=${encodeURIComponent(pathToFileURL(path).href)}`
    )
    expect(fileURL.status).toBe(200)
    expect(Buffer.from(await fileURL.arrayBuffer())).toEqual(bytes)

    const head = await fetch(`${server.url}/v1/fs/file?path=${encodeURIComponent(path)}`, {
      method: "HEAD"
    })
    expect(head.status).toBe(200)
    expect(head.headers.get("content-length")).toBe(String(bytes.byteLength))
    expect(head.headers.get("etag")).toMatch(/^"[0-9a-f]+-[0-9a-f]+"$/)
    expect((await head.arrayBuffer()).byteLength).toBe(0)

    const partial = await fetch(
      `${server.url}/v1/fs/file?path=${encodeURIComponent(`${path}:12`)}`,
      { headers: { Range: "bytes=2-5" } }
    )
    expect(partial.status).toBe(206)
    expect(partial.headers.get("content-range")).toBe(`bytes 2-5/${bytes.byteLength}`)
    expect(await partial.text()).toBe("2345")

    const invalidRange = await fetch(`${server.url}/v1/fs/file?path=${encodeURIComponent(path)}`, {
      headers: { Range: "bytes=99-100" }
    })
    expect(invalidRange.status).toBe(416)
    expect(invalidRange.headers.get("content-range")).toBe(`bytes */${bytes.byteLength}`)

    const unknownTypePath = join(root, "opaque.codevisor-preview")
    writeFileSync(unknownTypePath, "opaque")
    const unknownType = await fetch(
      `${server.url}/v1/fs/file?path=${encodeURIComponent(unknownTypePath)}`
    )
    expect(unknownType.status).toBe(200)
    expect(unknownType.headers.get("content-type")).toBe("application/octet-stream")

    const project = await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: root, id: "live-file-project" }),
      method: "POST"
    })
    const session = await jsonRequest(server, "/v1/sessions", {
      body: JSON.stringify({
        projectId: (project.body as { readonly id: string }).id,
        harnessId: "codex"
      }),
      method: "POST"
    })
    const sessionId = (session.body as { readonly id: string }).id
    const relative = await fetch(
      `${server.url}/v1/fs/file?path=${encodeURIComponent("report 2026.pdf")}&sessionId=${encodeURIComponent(sessionId.toUpperCase())}`
    )
    expect(relative.status).toBe(200)
    expect(Buffer.from(await relative.arrayBuffer())).toEqual(bytes)

    expect((await fetch(`${server.url}/v1/fs/file`)).status).toBe(400)
    expect((await fetch(`${server.url}/v1/fs/file?path=`)).status).toBe(400)
    expect(
      (
        await fetch(
          `${server.url}/v1/fs/file?path=${encodeURIComponent("file://example.com/report.pdf")}`
        )
      ).status
    ).toBe(400)
    expect((await fetch(`${server.url}/v1/fs/file?path=${encodeURIComponent("~")}`)).status).toBe(
      400
    )
    expect(
      (
        await fetch(
          `${server.url}/v1/fs/file?path=${encodeURIComponent(`~/codevisor-missing-${randomUUID()}`)}`
        )
      ).status
    ).toBe(404)
    expect((await fetch(`${server.url}/v1/fs/file?path=missing.pdf`)).status).toBe(400)
    expect(
      (
        await fetch(
          `${server.url}/v1/fs/file?path=${encodeURIComponent(join(root, "missing.pdf"))}`
        )
      ).status
    ).toBe(404)
    expect((await fetch(`${server.url}/v1/fs/file?path=${encodeURIComponent(root)}`)).status).toBe(
      400
    )

    const nonDirectory = join(root, "not-a-directory")
    writeFileSync(nonDirectory, "file")
    expect(
      (
        await fetch(
          `${server.url}/v1/fs/file?path=${encodeURIComponent(join(nonDirectory, "child"))}`
        )
      ).status
    ).toBe(500)

    const sealed = join(root, "sealed")
    const privatePath = join(sealed, "private.txt")
    mkdirSync(sealed)
    writeFileSync(privatePath, "private")
    chmodSync(sealed, 0o000)
    let denied: Response
    try {
      denied = await fetch(`${server.url}/v1/fs/file?path=${encodeURIComponent(privatePath)}`)
    } finally {
      chmodSync(sealed, 0o755)
    }
    expect(denied!.status).toBe(403)
  })
})
