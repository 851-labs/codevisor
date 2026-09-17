import { EventEmitter } from "node:events"
import * as fs from "node:fs"
import type { IncomingMessage, ServerResponse } from "node:http"
import { homedir, tmpdir } from "node:os"
import { join } from "node:path"
import { Readable } from "node:stream"

import { afterEach, beforeEach, expect, it, vi } from "vitest"

import { routeFileDocuments } from "./file-documents.js"
import { searchFileEntries } from "./file-search.js"

vi.mock("node:fs", async (original) => {
  const actual = await original<typeof fs>()
  return {
    ...actual,
    fsyncSync: vi.fn(actual.fsyncSync),
    closeSync: vi.fn(actual.closeSync),
    realpathSync: vi.fn(actual.realpathSync),
    statSync: vi.fn(actual.statSync)
  }
})
vi.mock("node:os", async (original) => ({
  ...(await original<typeof import("node:os")>()),
  homedir: vi.fn()
}))
vi.mock("./file-search.js", async (original) => {
  const actual = await original<typeof import("./file-search.js")>()
  return { ...actual, searchFileEntries: vi.fn(actual.searchFileEntries) }
})

let root: string
beforeEach(() => {
  root = fs.realpathSync(fs.mkdtempSync(join(tmpdir(), "codevisor-document-boundaries-")))
  vi.mocked(homedir).mockReturnValue(root)
})
afterEach(() => {
  vi.resetAllMocks()
  fs.rmSync(root, { recursive: true, force: true })
})

const response = () =>
  Object.assign(new EventEmitter(), {
    setHeader: vi.fn(),
    writeHead: vi.fn(),
    end: vi.fn()
  })

const invoke = async (endpoint: string, method = "GET", body?: unknown) => {
  const request = Readable.from(body === undefined ? [] : [Buffer.from(JSON.stringify(body))])
  Object.assign(request, { method })
  const output = response()
  const handled = await routeFileDocuments(
    request as IncomingMessage,
    output as unknown as ServerResponse,
    new URL(endpoint, "http://localhost")
  )
  return { handled, output, body: JSON.parse(output.end.mock.calls[0]![0]) }
}
const endpoint = (route: string, path: string) => `/v1/fs/${route}?path=${encodeURIComponent(path)}`
const document = (path: string) => endpoint("document", path)
const create = (content: string | Buffer = "original") => {
  const path = join(root, "file.txt")
  fs.writeFileSync(path, content)
  return path
}

it("leaves unrelated routes for the next handler", async () => {
  const output = response()
  expect(
    await routeFileDocuments(
      { method: "GET" } as IncomingMessage,
      output as unknown as ServerResponse,
      new URL("http://localhost/v1/sessions")
    )
  ).toBe(false)
  expect(output.end).not.toHaveBeenCalled()
})

it("expands the machine home and responds to unchanged document revisions", async () => {
  const path = create()
  await expect(invoke(document("~"))).rejects.toMatchObject({ code: "not_a_file" })
  const loaded = await invoke(document("~/file.txt"))
  expect(loaded.body).toMatchObject({ path, content: "original", reason: null })
  expect(loaded.output.setHeader).toHaveBeenCalledWith("Cache-Control", "private, no-store")
  expect((await invoke(`${document(path)}&version=${loaded.body.version}`)).body).toEqual({
    unchanged: true
  })
  await expect(invoke("/v1/fs/document")).rejects.toMatchObject({ code: "invalid_path" })
})

it.each([
  "bad",
  null,
  {},
  { content: "" },
  { content: 1, version: "v" },
  { content: "", version: 1 }
])("rejects malformed save payload %j without modifying the file", async (body) => {
  const path = create()
  await expect(invoke(document(path), "PUT", body)).rejects.toMatchObject({
    code: "invalid_request"
  })
  expect(fs.readFileSync(path, "utf8")).toBe("original")
})

it.each(["\0", "x".repeat(4 * 1024 * 1024 + 1)])(
  "rejects unsupported save contents %#",
  async (content) => {
    const path = create()
    await expect(invoke(document(path), "PUT", { content, version: "v" })).rejects.toMatchObject({
      status: 413,
      code: "file_too_large"
    })
    expect(fs.readFileSync(path, "utf8")).toBe("original")
  }
)

it("marks invalid UTF-8, oversized files, and hard-linked files as uneditable", async () => {
  const path = create(Buffer.from([255]))
  expect((await invoke(document(path))).body).toMatchObject({ content: null, writable: false })
  fs.writeFileSync(path, "x".repeat(4 * 1024 * 1024 + 1))
  expect((await invoke(document(path))).body).toMatchObject({
    content: null,
    writable: false,
    reason: expect.stringContaining("too large")
  })
  fs.writeFileSync(path, "linked")
  fs.linkSync(path, join(root, "alias.txt"))
  const loaded = await invoke(document(path))
  expect(loaded.body).toMatchObject({
    content: "linked",
    writable: false,
    reason: "This file is read-only."
  })
  await expect(
    invoke(document(path), "PUT", { content: "edit", version: loaded.body.version })
  ).rejects.toMatchObject({ status: 403, code: "permission_denied" })
})

it("detects an external edit during a save and removes the temporary file", async () => {
  const path = create()
  const loaded = await invoke(document(path))
  vi.mocked(fs.fsyncSync).mockImplementationOnce(() => fs.writeFileSync(path, "external edit"))
  await expect(
    invoke(document(path), "PUT", { content: "my edit", version: loaded.body.version })
  ).rejects.toMatchObject({ status: 409, message: expect.stringContaining("while saving") })
  expect(fs.readFileSync(path, "utf8")).toBe("external edit")
  expect(fs.readdirSync(root)).toEqual(["file.txt"])
})

it("closes the descriptor and removes temporary data after a failed disk write", async () => {
  const path = create()
  const loaded = await invoke(document(path))
  const failure = Object.assign(new Error("disk full"), { code: "ENOSPC" })
  vi.mocked(fs.fsyncSync).mockImplementationOnce(() => {
    throw failure
  })
  await expect(
    invoke(document(path), "PUT", { content: "my edit", version: loaded.body.version })
  ).rejects.toBe(failure)
  expect(fs.closeSync).toHaveBeenCalledWith(vi.mocked(fs.fsyncSync).mock.calls[0]![0])
  expect(fs.readdirSync(root)).toEqual(["file.txt"])
  expect(fs.readFileSync(path, "utf8")).toBe("original")
})

it.each(["EACCES", "EPERM", "ENOTDIR", "EIO"])("reports filesystem error %s", async (code) => {
  const failure = Object.assign(new Error(code), { code })
  vi.mocked(fs.realpathSync).mockImplementationOnce(() => {
    throw failure
  })
  const pending = invoke(document(join(root, "file.txt")))
  if (code === "EIO") await expect(pending).rejects.toBe(failure)
  else
    await expect(pending).rejects.toMatchObject({
      status: code === "ENOTDIR" ? 400 : 403,
      code: code === "ENOTDIR" ? "not_a_directory" : "permission_denied"
    })
})

it("lists hidden entries and directories while skipping dangling and nonregular files", async () => {
  create()
  fs.mkdirSync(join(root, "folder"))
  fs.writeFileSync(join(root, ".hidden"), "hidden")
  fs.symlinkSync(join(root, "missing"), join(root, "broken"))
  const listed = await invoke(`${endpoint("entries", root)}&showHidden=true`)
  expect(listed.body.entries.map((entry: { name: string }) => entry.name)).toEqual([
    "folder",
    ".hidden",
    "file.txt"
  ])
  expect(listed.body.entries[0].isDirectory).toBe(true)
  fs.rmSync(join(root, "folder"), { recursive: true })
  fs.rmSync(join(root, ".hidden"))
  fs.rmSync(join(root, "broken"))
  vi.mocked(fs.statSync).mockReturnValueOnce({
    isDirectory: () => false,
    isFile: () => false
  } as fs.Stats)
  expect((await invoke(endpoint("entries", root))).body.entries).toEqual([])
})

it.each(["document", "entries", "search"])("rejects unsupported methods for %s", async (route) => {
  await expect(invoke(endpoint(route, root), "DELETE")).rejects.toMatchObject({
    status: 405,
    code: "method_not_allowed"
  })
})

it("serves recursive searches and removes its disconnect listener after completion", async () => {
  fs.mkdirSync(join(root, "nested"))
  fs.writeFileSync(join(root, "nested", "settings.json"), "{}")
  const result = await invoke(`${endpoint("search", root)}&query=settings`)
  expect(result.body.entries).toMatchObject([{ path: join(root, "nested", "settings.json") }])
  expect(result.output.setHeader).toHaveBeenCalledWith("Cache-Control", "private, no-store")
  expect(result.output.listenerCount("close")).toBe(0)
  expect((await invoke(endpoint("search", root))).body.entries).toEqual([])
})

it("cancels a search when its response disconnects and releases the listener", async () => {
  vi.mocked(searchFileEntries).mockImplementationOnce(
    (_root, _query, options) =>
      new Promise((_resolve, reject) => {
        options!.signal!.addEventListener("abort", () => reject(options!.signal!.reason), {
          once: true
        })
      })
  )
  const output = response()
  const pending = routeFileDocuments(
    { method: "GET" } as IncomingMessage,
    output as unknown as ServerResponse,
    new URL(endpoint("search", root), "http://localhost")
  )
  const cancelled = expect(pending).rejects.toMatchObject({ name: "AbortError" })
  output.emit("close")
  await cancelled
  expect(output.listenerCount("close")).toBe(0)
  expect(output.end).not.toHaveBeenCalled()
})
