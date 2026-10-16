import { mkdtemp, readdir, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import sharp from "sharp"
import { afterEach, describe, expect, it } from "vitest"

import {
  makeLinkPreviewStore,
  normalizePreviewUrl,
  renderPreviewImage,
  type LinkPreviewStoreOptions
} from "./link-previews.js"

const directories: Array<string> = []
afterEach(async () => {
  await Promise.all(directories.splice(0).map((dir) => rm(dir, { recursive: true, force: true })))
})

const picture = (width: number, height: number, alpha: number): Promise<Buffer> =>
  sharp({
    create: { width, height, channels: 4, background: { r: 240, g: 128, b: 0, alpha } }
  })
    .png()
    .toBuffer()

type Route = () => Response

const html =
  (head: string): Route =>
  () =>
    new Response(`<html><head>${head}</head><body>page</body></html>`, {
      headers: { "content-type": "text/html" }
    })

const bytes =
  (data: Uint8Array): Route =>
  () =>
    new Response(Buffer.from(data))

const store = async (
  routes: Record<string, Route>,
  overrides: Partial<LinkPreviewStoreOptions> = {}
) => {
  const dir = await mkdtemp(join(tmpdir(), "link-previews-"))
  directories.push(dir)
  const requested: Array<string> = []
  const fetchImpl = (async (input: string | URL | Request) => {
    const url = input instanceof Request ? input.url : input.toString()
    requested.push(url)
    return routes[url]?.() ?? new Response(null, { status: 404 })
  }) as typeof fetch
  let now = 1_000_000
  const refreshes: Array<Promise<unknown>> = []
  const previews = makeLinkPreviewStore({
    dir,
    fetchImpl,
    now: () => now,
    background: (refresh) => {
      refreshes.push(refresh)
    },
    ...overrides
  })
  return {
    dir,
    previews,
    requested,
    advance: (ms: number) => {
      now += ms
    },
    refreshes
  }
}

const HOUR = 60 * 60 * 1000

describe("link preview images", () => {
  it("shrinks opaque images to JPEG and keeps transparency as PNG, with the dominant color", async () => {
    const opaque = await renderPreviewImage(await picture(1600, 840, 1))
    expect(opaque).toMatchObject({ width: 800, height: 420, image: { contentType: "image/jpeg" } })
    expect(opaque?.color).toMatch(/^#[\da-f]{6}$/)
    const clear = await renderPreviewImage(await picture(40, 20, 0.5))
    expect(clear).toMatchObject({ width: 40, height: 20, image: { contentType: "image/png" } })
  })

  it("refuses icons, vectors, unknown bytes and broken images", async () => {
    expect(await renderPreviewImage(Buffer.from([0x00, 0x00, 0x01, 0x00]))).toBeUndefined()
    expect(await renderPreviewImage(Buffer.from("<svg></svg>"))).toBeUndefined()
    expect(await renderPreviewImage(Buffer.from("plain text"))).toBeUndefined()
    expect(await renderPreviewImage(Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2]))).toBeUndefined()
  })

  it("keeps web URLs without their fragment", () => {
    expect(normalizePreviewUrl("https://a.test/page#section")).toBe("https://a.test/page")
    expect(normalizePreviewUrl("ftp://a.test/file")).toBeUndefined()
    expect(normalizePreviewUrl("not a url")).toBeUndefined()
  })
})

describe("link preview store", () => {
  it("builds a preview from the page and its image, and serves both from the cache", async () => {
    const image = await picture(1200, 630, 1)
    const { previews, requested, dir } = await store({
      "https://site.test/post": html(
        `<meta property="og:title" content="Post"><meta property="og:description" content="About">
         <meta property="og:site_name" content="Site"><meta property="og:image" content="/card.png">`
      ),
      "https://site.test/card.png": bytes(image)
    })
    const preview = await previews.preview("https://site.test/post#top")
    expect(preview).toMatchObject({
      url: "https://site.test/post",
      title: "Post",
      description: "About",
      siteName: "Site",
      image: { width: 800, height: 420 }
    })
    expect((await previews.image("https://site.test/post"))?.contentType).toBe("image/jpeg")
    expect(requested).toEqual(["https://site.test/post", "https://site.test/card.png"])
    expect((await readdir(dir)).toSorted().map((name) => name.split(".").at(-1))).toEqual([
      "img",
      "json"
    ])

    const reopened = makeLinkPreviewStore({ dir, fetchImpl: () => Promise.reject(new Error()) })
    expect(await reopened.preview("https://site.test/post")).toEqual(preview)
  })

  it("titles a direct image link with its file name", async () => {
    const image = await picture(20, 20, 1)
    const { previews } = await store({
      "https://cdn.test/shots/my%20shot.png": bytes(image),
      "https://cdn.test/shots/bad%E0%A4%A.png": bytes(image),
      "https://cdn.test/": bytes(image)
    })
    expect((await previews.preview("https://cdn.test/shots/my%20shot.png"))?.title).toBe(
      "my shot.png"
    )
    expect((await previews.preview("https://cdn.test/shots/bad%E0%A4%A.png"))?.title).toBe(
      "bad%E0%A4%A.png"
    )
    const untitled = await previews.preview("https://cdn.test/")
    expect(untitled?.title).toBeUndefined()
    expect(untitled?.image).toMatchObject({ width: 20, height: 20 })
  })

  it("remembers pages without a preview for an hour", async () => {
    const { previews, requested, advance } = await store({
      "https://site.test/bare": html("<meta charset=utf-8>")
    })
    expect(await previews.preview("https://site.test/missing")).toBeUndefined()
    expect(await previews.preview("https://site.test/bare")).toBeUndefined()
    expect(await previews.image("https://site.test/bare")).toBeUndefined()
    expect(requested).toHaveLength(2)
    advance(HOUR)
    expect(await previews.preview("https://site.test/bare")).toBeUndefined()
    expect(requested).toHaveLength(3)
    expect(await previews.preview("mailto:someone@site.test")).toBeUndefined()
    expect(requested).toHaveLength(3)
  })

  it("retries a failed image after an hour and refreshes good previews after a day", async () => {
    const image = await picture(10, 10, 1)
    const { previews, requested, advance, refreshes } = await store({
      "https://site.test/limited": html(
        `<title>Limited</title><meta property="og:image" content="https://img.test/a.png">`
      ),
      "https://site.test/fine": html(
        `<title>Fine</title><meta property="og:image" content="https://img.test/b.png">`
      ),
      "https://img.test/b.png": bytes(image)
    })
    expect(await previews.preview("https://site.test/limited")).toEqual({
      url: "https://site.test/limited",
      title: "Limited"
    })
    expect(await previews.preview("https://site.test/fine")).toMatchObject({ title: "Fine" })
    advance(HOUR - 1)
    await previews.preview("https://site.test/limited")
    expect(refreshes).toHaveLength(0)
    advance(1)
    await previews.preview("https://site.test/limited")
    await previews.preview("https://site.test/fine")
    expect(refreshes).toHaveLength(1)
    await Promise.all(refreshes)
    advance(24 * HOUR)
    await previews.preview("https://site.test/fine")
    expect(refreshes).toHaveLength(2)
    await Promise.all(refreshes)
    expect(requested.filter((url) => url === "https://img.test/a.png")).toHaveLength(2)
  })

  it("shares one fetch between concurrent requests", async () => {
    const { previews, requested } = await store({
      "https://site.test/": html("<title>Home</title>")
    })
    const [first, second] = await Promise.all([
      previews.preview("https://site.test/"),
      previews.image("https://site.test/")
    ])
    expect(first?.title).toBe("Home")
    expect(second).toBeUndefined()
    expect(requested).toEqual(["https://site.test/"])
  })

  it("follows meta refresh pages a couple of hops", async () => {
    const { previews, requested } = await store({
      "https://docs.test/": html(
        `<title>Redirect</title><meta http-equiv="refresh" content="0;url=/a">`
      ),
      "https://docs.test/a": html(`<title>A</title><meta http-equiv="refresh" content="0;url=/b">`),
      "https://docs.test/b": html(`<title>B</title><meta http-equiv="refresh" content="0;url=/c">`)
    })
    expect(await previews.preview("https://docs.test/")).toEqual({
      url: "https://docs.test/b",
      title: "B"
    })
    expect(requested).toEqual(["https://docs.test/", "https://docs.test/a", "https://docs.test/b"])
  })

  it("refetches over a corrupt cache and still answers when the cache can't be written", async () => {
    const { previews, dir, requested } = await store({
      "https://site.test/": html("<title>Home</title>")
    })
    await previews.preview("https://site.test/")
    const [record] = await readdir(dir)
    await writeFile(join(dir, record!), "{")
    expect((await previews.preview("https://site.test/"))?.title).toBe("Home")
    expect(requested).toHaveLength(2)

    const file = join(dir, "not-a-directory")
    await writeFile(file, "")
    const unwritable = makeLinkPreviewStore({
      dir: file,
      fetchImpl: async () => html("<title>Home</title>")()
    })
    expect((await unwritable.preview("https://site.test/"))?.title).toBe("Home")
  })
})
