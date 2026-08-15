import Database from "better-sqlite3"
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  utimesSync,
  writeFileSync
} from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { describe, expect, it } from "vitest"
import { sweepAttachmentTempFiles } from "../server.js"
import { jsonRequest, run, start, tempDirs, waitFor } from "../test-support.js"

describe("file routes", () => {
  it("stores files and threads prompt attachments end to end", async () => {
    const { agents, server, services } = await start()
    const projectRoot = mkdtempSync(join(tmpdir(), "codevisor-server-attachments-"))
    tempDirs.push(projectRoot)
    const projectFolder = join(projectRoot, "project")
    mkdirSync(projectFolder)

    const upload = async (
      body: Uint8Array,
      options: { name?: string; contentType?: string } = {}
    ) => {
      const query = options.name === undefined ? "" : `?name=${encodeURIComponent(options.name)}`
      const response = await fetch(`${server.url}/v1/files${query}`, {
        body: body as unknown as BodyInit,
        headers: options.contentType === undefined ? {} : { "Content-Type": options.contentType },
        method: "POST"
      })
      return { body: (await response.json()) as Record<string, unknown>, status: response.status }
    }

    // Kind is sniffed from magic bytes, with the declared mime as fallback.
    const pngBytes = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3])
    const png = await upload(pngBytes, { contentType: "image/png", name: "shot.png" })
    expect(png.status).toBe(201)
    expect(png.body).toMatchObject({
      kind: "image",
      mimeType: "image/png",
      name: "shot.png",
      sizeBytes: pngBytes.byteLength
    })
    const pngStorage = await run(services.db.getFileStorage(String(png.body.id)))
    expect(pngStorage).toMatchObject({ storageState: "disk", data: Buffer.alloc(0) })
    expect(existsSync(services.attachments.objectPath(String(png.body.sha256)))).toBe(true)
    const jpeg = await upload(Buffer.from([0xff, 0xd8, 0xff, 0xe0, 9, 9]), { name: "raw.bin" })
    expect(jpeg.body).toMatchObject({ kind: "image", mimeType: "application/octet-stream" })
    const gif = await upload(Buffer.from("GIF89a-data"), { contentType: "image/gif" })
    expect(gif.body).toMatchObject({ kind: "image" })
    const webpBytes = Buffer.concat([
      Buffer.from("RIFF"),
      Buffer.from([16, 0, 0, 0]),
      Buffer.from("WEBPVP8 ")
    ])
    expect((await upload(webpBytes, { contentType: "video/webm" })).body).toMatchObject({
      kind: "image"
    })
    const svg = await upload(Buffer.from("<svg/>"), {
      contentType: "image/svg+xml; charset=utf-8",
      name: "../evil/pic.svg"
    })
    expect(svg.body).toMatchObject({
      kind: "image",
      mimeType: "image/svg+xml",
      name: "_evil_pic.svg"
    })
    const text = await upload(Buffer.from("hello"), { contentType: "text/plain", name: "..." })
    expect(text.body).toMatchObject({ kind: "file", mimeType: "text/plain", name: "attachment" })

    // Download round-trips bytes with immutable caching; unknown ids 404.
    const download = await fetch(`${server.url}/v1/files/${String(png.body.id)}`)
    expect(download.status).toBe(200)
    expect(download.headers.get("content-type")).toBe("image/png")
    expect(download.headers.get("cache-control")).toContain("immutable")
    expect(Buffer.from(await download.arrayBuffer()).equals(pngBytes)).toBe(true)
    const head = await fetch(`${server.url}/v1/files/${String(png.body.id)}`, { method: "HEAD" })
    expect(head.status).toBe(200)
    expect(head.headers.get("accept-ranges")).toBe("bytes")
    expect(head.headers.get("content-length")).toBe(String(pngBytes.byteLength))
    expect((await head.arrayBuffer()).byteLength).toBe(0)
    const partial = await fetch(`${server.url}/v1/files/${String(png.body.id)}`, {
      headers: { Range: "bytes=4-7" }
    })
    expect(partial.status).toBe(206)
    expect(partial.headers.get("content-range")).toBe(`bytes 4-7/${pngBytes.byteLength}`)
    expect(Buffer.from(await partial.arrayBuffer()).equals(pngBytes.subarray(4, 8))).toBe(true)
    const suffix = await fetch(`${server.url}/v1/files/${String(png.body.id)}`, {
      headers: { Range: "bytes=-4" }
    })
    expect(suffix.status).toBe(206)
    expect(Buffer.from(await suffix.arrayBuffer()).equals(pngBytes.subarray(-4))).toBe(true)
    const openEnded = await fetch(`${server.url}/v1/files/${String(png.body.id)}`, {
      headers: { Range: "bytes=4-" }
    })
    expect(openEnded.status).toBe(206)
    expect(Buffer.from(await openEnded.arrayBuffer()).equals(pngBytes.subarray(4))).toBe(true)
    const capped = await fetch(`${server.url}/v1/files/${String(png.body.id)}`, {
      headers: { Range: "bytes=4-999" }
    })
    expect(capped.status).toBe(206)
    expect(Buffer.from(await capped.arrayBuffer()).equals(pngBytes.subarray(4))).toBe(true)
    const invalidRange = await fetch(`${server.url}/v1/files/${String(png.body.id)}`, {
      headers: { Range: "bytes=999-1000" }
    })
    expect(invalidRange.status).toBe(416)
    for (const range of [
      "items=0-1",
      "bytes=-0",
      "bytes=7-4",
      "bytes=999999999999999999999-",
      "bytes=0-999999999999999999999"
    ]) {
      expect(
        (
          await fetch(`${server.url}/v1/files/${String(png.body.id)}`, {
            headers: { Range: range }
          })
        ).status
      ).toBe(416)
    }
    const empty = await upload(Buffer.alloc(0), { name: "empty.txt" })
    expect(
      (
        await fetch(`${server.url}/v1/files/${String(empty.body.id)}`, {
          headers: { Range: "bytes=0-0" }
        })
      ).status
    ).toBe(416)
    expect((await fetch(`${server.url}/v1/files/missing-file`)).status).toBe(404)

    // The former 25 MB cap is gone; large uploads stream to the object store.
    const largeBytes = Buffer.alloc(25 * 1024 * 1024 + 1, 0x7a)
    const large = await upload(largeBytes, {
      contentType: "application/octet-stream",
      name: "large.bin"
    })
    expect(large.status).toBe(201)
    expect(large.body).toMatchObject({ name: "large.bin", sizeBytes: largeBytes.byteLength })
    expect(statSync(services.attachments.objectPath(String(large.body.sha256))).size).toBe(
      largeBytes.byteLength
    )
    const afterLarge = await upload(Buffer.from("still healthy"), {
      contentType: "text/plain",
      name: "after-large.txt"
    })
    expect(afterLarge.status).toBe(201)

    const sessionResponse = await jsonRequest(server, "/v1/sessions", {
      body: JSON.stringify({
        projectId: (
          (
            await jsonRequest(server, "/v1/projects", {
              body: JSON.stringify({ folderPath: projectFolder, id: "attachment-project" }),
              method: "POST"
            })
          ).body as { readonly id: string }
        ).id,
        harnessId: "codex"
      }),
      method: "POST"
    })
    const session = sessionResponse.body as { readonly id: string }

    const pngRef = {
      fileId: String(png.body.id),
      kind: "image" as const,
      mimeType: "image/png",
      name: "shot.png",
      sizeBytes: pngBytes.byteLength
    }
    const textRef = {
      fileId: String(text.body.id),
      kind: "file" as const,
      mimeType: "text/plain",
      name: "attachment",
      sizeBytes: 5
    }

    // Unknown file ids and over-limit attachment counts fail at send time.
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({
            attachments: [{ ...pngRef, fileId: "missing-file" }],
            text: "nope"
          }),
          method: "POST"
        })
      ).status
    ).toBe(422)
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ attachments: Array(11).fill(pngRef), text: "too many" }),
          method: "POST"
        })
      ).status
    ).toBe(422)

    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ attachments: [pngRef, textRef], text: "look at these" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ accepted: true })
    await waitFor(() => agents.prompts.length === 1)
    const promptInput = agents.prompts[0]?.[1]
    expect(promptInput).toMatchObject({
      attachments: [
        { kind: "image", mimeType: "image/png", name: "shot.png" },
        { kind: "file", mimeType: "text/plain", name: "attachment" }
      ],
      text: "look at these"
    })
    const materialized = (promptInput as { attachments: ReadonlyArray<{ path: string }> })
      .attachments[0]?.path
    expect(materialized).toBeTruthy()
    expect(readFileSync(String(materialized)).equals(pngBytes)).toBe(true)

    // Re-sending the same attachment reuses the materialized temp file.
    await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
      body: JSON.stringify({ attachments: [pngRef], text: "again" }),
      method: "POST"
    })
    await waitFor(() => agents.prompts.length === 2)

    // The persisted user message and its replayed event both carry the refs.
    const detail = (await jsonRequest(server, `/v1/sessions/${session.id}`)).body as {
      readonly conversation: ReadonlyArray<{
        readonly text: string
        readonly attachments?: ReadonlyArray<{ readonly fileId: string }>
      }>
    }
    const userItem = detail.conversation.find((item) => item.text === "look at these")
    expect(userItem?.attachments).toMatchObject([
      { fileId: pngRef.fileId },
      { fileId: textRef.fileId }
    ])
    const history = (await jsonRequest(server, `/v1/sessions/${session.id}/events`))
      .body as ReadonlyArray<{ readonly payload: Record<string, unknown> }>
    expect(
      history.some(
        (event) =>
          event.payload.text === "look at these" && Array.isArray(event.payload.attachments)
      )
    ).toBe(true)

    // A queued attachment whose file has vanished surfaces a session error at
    // drain time instead of crashing the queue.
    await run(
      services.db.createPromptQueueItem(session.id, "stale file", [
        { ...pngRef, fileId: "vanished-file" }
      ])
    )
    await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
      body: JSON.stringify({ text: "after stale" }),
      method: "POST"
    })
    await waitFor(async () => {
      const events = (await jsonRequest(server, `/v1/sessions/${session.id}/events`))
        .body as ReadonlyArray<{ readonly kind: string; readonly payload: Record<string, unknown> }>
      return events.some(
        (event) =>
          event.kind === "session.error" && String(event.payload.message).includes("vanished-file")
      )
    })

    // A user payload with malformed attachments is not a conversation item.
    const agentSessionId = agents.prompts[0]?.[0] as string
    await agents.emit(agentSessionId, {
      kind: "session.output",
      payload: { attachments: "bogus", role: "user", text: "malformed" },
      subjectId: agentSessionId
    })
    await waitFor(async () => {
      const events = (await jsonRequest(server, `/v1/sessions/${session.id}/events`))
        .body as ReadonlyArray<{ readonly payload: Record<string, unknown> }>
      return events.some((event) => event.payload.text === "malformed")
    })
    const refreshed = (await jsonRequest(server, `/v1/sessions/${session.id}`)).body as {
      readonly conversation: ReadonlyArray<{ readonly text: string }>
    }
    expect(refreshed.conversation.some((item) => item.text === "malformed")).toBe(false)

    // A corrupt disk-only object cannot fall back to SQLite and surfaces the
    // storage error through prompt attachment resolution.
    writeFileSync(
      services.attachments.objectPath(String(png.body.sha256)),
      Buffer.alloc(pngBytes.byteLength, 0)
    )
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ attachments: [pngRef], text: "corrupt disk object" }),
          method: "POST"
        })
      ).status
    ).toBe(202)
    await waitFor(async () => {
      const events = (await jsonRequest(server, `/v1/sessions/${session.id}/events`))
        .body as ReadonlyArray<{ readonly kind: string; readonly payload: Record<string, unknown> }>
      return events.some(
        (event) =>
          event.kind === "session.error" &&
          String(event.payload.message).includes("missing or corrupt")
      )
    })
    rmSync(services.attachments.objectPath(String(png.body.sha256)), { force: true })
    expect((await fetch(`${server.url}/v1/files/${String(png.body.id)}`)).status).toBe(500)
  })

  it("recovers legacy attachment rows and rejects corrupt SQLite bytes", async () => {
    const { server, services } = await start()
    const legacyBytes = Buffer.from("legacy server attachment")
    const legacy = await run(
      services.db.createFile("legacy.txt", "text/plain", "file", legacyBytes)
    )

    const legacyResponse = await fetch(`${server.url}/v1/files/${legacy.id}`)
    expect(legacyResponse.status).toBe(200)
    expect(Buffer.from(await legacyResponse.arrayBuffer())).toEqual(legacyBytes)
    expect(await run(services.db.getFileStorage(legacy.id))).toMatchObject({
      storageState: "dual"
    })
    expect(await services.attachments.verify(legacy)).toBe(true)

    const dualBytes = Buffer.from("recoverable dual attachment")
    const dual = await run(services.db.createFile("dual.txt", "text/plain", "file", dualBytes))
    await services.attachments.put(dualBytes, dual.sha256)
    await run(services.db.markFileStorageDual(dual.id))
    writeFileSync(
      services.attachments.objectPath(dual.sha256),
      Buffer.alloc(dualBytes.byteLength, 0)
    )
    const dualResponse = await fetch(`${server.url}/v1/files/${dual.id}`)
    expect(dualResponse.status).toBe(200)
    expect(Buffer.from(await dualResponse.arrayBuffer())).toEqual(dualBytes)
    expect(await services.attachments.verify(dual)).toBe(true)

    const database = new Database(join(dirname(services.attachments.root), "codevisor.sqlite"))
    const wrongSize = await run(
      services.db.createFile("wrong-size.txt", "text/plain", "file", Buffer.from("correct"))
    )
    database
      .prepare("update files set data = ? where id = ?")
      .run(Buffer.from("wrong size"), wrongSize.id)
    expect((await fetch(`${server.url}/v1/files/${wrongSize.id}`)).status).toBe(500)

    const wrongHash = await run(
      services.db.createFile("wrong-hash.txt", "text/plain", "file", Buffer.from("correct"))
    )
    database
      .prepare("update files set data = ? where id = ?")
      .run(Buffer.from("xxxxxxx"), wrongHash.id)
    expect((await fetch(`${server.url}/v1/files/${wrongHash.id}`)).status).toBe(500)
    database.close()
  })

  it("sweeps stale materialized attachment temp files at startup", async () => {
    const root = join(tmpdir(), "codevisor-attachments")
    mkdirSync(root, { recursive: true })
    const stale = join(root, "sweep-test-stale")
    const fresh = join(root, "sweep-test-fresh")
    mkdirSync(stale, { recursive: true })
    mkdirSync(fresh, { recursive: true })
    const old = new Date(Date.now() - 8 * 24 * 60 * 60 * 1000)
    utimesSync(stale, old, old)

    sweepAttachmentTempFiles()
    expect(existsSync(stale)).toBe(false)
    expect(existsSync(fresh)).toBe(true)

    // A missing temp root is a no-op, not an error.
    rmSync(root, { force: true, recursive: true })
    sweepAttachmentTempFiles(Date.now())
    expect(existsSync(root)).toBe(false)
  })
})
