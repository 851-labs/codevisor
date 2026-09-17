import { mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import sharp from "sharp"
import { expect, it, onTestFinished } from "vitest"

import { start } from "../test-support.js"

it("serves bounded file and filesystem previews without changing original download bytes", async () => {
  const { server } = await start()
  const root = await mkdtemp(join(tmpdir(), "codevisor-preview-route-"))
  onTestFinished(() => rm(root, { recursive: true, force: true }))
  const bytes = await sharp({
    create: { width: 1200, height: 800, channels: 3, background: "blue" }
  })
    .png()
    .toBuffer()
  const path = join(root, "image.png")
  await writeFile(path, bytes)
  const uploaded = await fetch(`${server.url}/v1/files?name=image.png`, {
    method: "POST",
    headers: { "Content-Type": "image/png" },
    body: new Uint8Array(bytes)
  })
  const file = (await uploaded.json()) as { id: string }
  for (const route of [`/v1/files/${file.id}`, `/v1/fs/file?path=${encodeURIComponent(path)}`]) {
    const preview = await fetch(`${server.url}${route}${route.includes("?") ? "&" : "?"}preview=1`)
    expect(preview.status).toBe(200)
    expect(preview.headers.get("content-type")).toBe("image/png")
    expect((await sharp(Buffer.from(await preview.arrayBuffer())).metadata()).width).toBe(480)
    expect(Buffer.from(await (await fetch(`${server.url}${route}`)).arrayBuffer())).toEqual(bytes)
  }
})
