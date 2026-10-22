import { createHash } from "node:crypto"
import { mkdir, readFile, rename, writeFile } from "node:fs/promises"
import { join } from "node:path"

import { Schema } from "effect"
import sharp, { type Sharp } from "sharp"

import { makeBoundedFetch } from "./bounded-fetch.js"
import { parseLinkPreviewMetadata } from "./link-preview-metadata.js"
import { sniffImageFormat } from "./tool-icon-images.js"

const HTML_MAX_BYTES = 2 * 1024 * 1024
const IMAGE_MAX_BYTES = 8 * 1024 * 1024
const FETCH_TIMEOUT_MS = 8_000
const IMAGE_PIXELS = 800
const HIT_TTL_MS = 24 * 60 * 60 * 1000
const MISS_TTL_MS = 60 * 60 * 1000
const MAX_HOPS = 2

export const LinkPreview = Schema.Struct({
  url: Schema.String,
  title: Schema.optionalKey(Schema.String),
  description: Schema.optionalKey(Schema.String),
  siteName: Schema.optionalKey(Schema.String),
  image: Schema.optionalKey(
    Schema.Struct({ width: Schema.Number, height: Schema.Number, color: Schema.String })
  )
})
export type LinkPreview = typeof LinkPreview.Type

export interface LinkPreviewImage {
  readonly contentType: "image/jpeg" | "image/png"
  readonly data: Uint8Array
}

export interface LinkPreviewStore {
  readonly preview: (url: string) => Promise<LinkPreview | undefined>
  readonly image: (url: string) => Promise<LinkPreviewImage | undefined>
}

export interface LinkPreviewStoreOptions {
  readonly dir: string
  readonly fetchImpl?: typeof fetch
  readonly now?: () => number
  readonly background?: (refresh: Promise<unknown>) => void
}

const CacheRecord = Schema.Struct({
  key: Schema.String,
  fetchedAt: Schema.Number,
  preview: Schema.optionalKey(LinkPreview),
  contentType: Schema.optionalKey(Schema.Literals(["image/jpeg", "image/png"])),
  imageFailed: Schema.optionalKey(Schema.Boolean)
})
type CacheRecord = typeof CacheRecord.Type

interface Entry {
  readonly preview?: LinkPreview
  readonly image?: LinkPreviewImage
  readonly imageFailed?: boolean
}

interface RenderedImage {
  readonly image: LinkPreviewImage
  readonly width: number
  readonly height: number
  readonly color: string
}

export const normalizePreviewUrl = (raw: string): string | undefined => {
  try {
    const url = new URL(raw)
    if (url.protocol !== "https:" && url.protocol !== "http:") return undefined
    url.hash = ""
    return url.toString()
  } catch {
    return undefined
  }
}

const hex = (value: number): string => Math.round(value).toString(16).padStart(2, "0")

export const renderPreviewImage = async (data: Uint8Array): Promise<RenderedImage | undefined> => {
  const format = sniffImageFormat(data)
  if (format === undefined || format === "ico" || format === "svg") return undefined
  try {
    const resized = sharp(data, { limitInputPixels: 40_000_000, animated: false }).resize({
      fit: "inside",
      width: IMAGE_PIXELS,
      height: IMAGE_PIXELS,
      withoutEnlargement: true
    })
    const stats = await resized.clone().stats()
    let encoded: Sharp
    if (stats.isOpaque) encoded = resized.jpeg({ quality: 82, mozjpeg: true })
    else encoded = resized.png({ compressionLevel: 9 })
    const { data: output, info } = await encoded.toBuffer({ resolveWithObject: true })
    const { r, g, b } = stats.dominant
    return {
      image: {
        contentType: stats.isOpaque ? "image/jpeg" : "image/png",
        data: new Uint8Array(output)
      },
      width: info.width,
      height: info.height,
      color: `#${hex(r)}${hex(g)}${hex(b)}`
    }
  } catch {
    return undefined
  }
}

const fileTitle = (url: string): string | undefined => {
  const name = new URL(url).pathname.split("/").at(-1)!
  if (name === "") return undefined
  try {
    return decodeURIComponent(name)
  } catch {
    return name
  }
}

export const makeLinkPreviewStore = (options: LinkPreviewStoreOptions): LinkPreviewStore => {
  const now = options.now ?? Date.now
  /* v8 ignore start */
  const fetchImpl = options.fetchImpl ?? globalThis.fetch
  const background =
    options.background ?? ((refresh: Promise<unknown>) => void refresh.catch(() => undefined))
  /* v8 ignore stop */
  const fetchBounded = makeBoundedFetch(fetchImpl, FETCH_TIMEOUT_MS)
  const inFlight = new Map<string, Promise<Entry | undefined>>()

  const resolve = async (url: string, hops = 0): Promise<Entry | undefined> => {
    const page = await fetchBounded(url, HTML_MAX_BYTES, "text/html,application/xhtml+xml")
    if (page === undefined) return undefined
    const direct = sniffImageFormat(page.data) === undefined ? undefined : page
    const metadata =
      direct === undefined
        ? parseLinkPreviewMetadata(new TextDecoder().decode(page.data), page.url)
        : {}
    if (metadata.refreshUrl !== undefined && metadata.imageUrl === undefined && hops < MAX_HOPS)
      return resolve(metadata.refreshUrl, hops + 1)
    const title = direct === undefined ? metadata.title : fileTitle(page.url)
    let source = direct
    if (direct === undefined && metadata.imageUrl !== undefined) {
      source = await fetchBounded(metadata.imageUrl, IMAGE_MAX_BYTES, "image/*")
    }
    let rendered: RenderedImage | undefined
    if (source !== undefined) rendered = await renderPreviewImage(source.data)
    if (title === undefined && rendered === undefined) return {}
    const imageFailed = metadata.imageUrl !== undefined && rendered === undefined
    const preview: LinkPreview = {
      url: page.url,
      ...(title === undefined ? {} : { title }),
      ...(metadata.description === undefined ? {} : { description: metadata.description }),
      ...(metadata.siteName === undefined ? {} : { siteName: metadata.siteName }),
      ...(rendered === undefined
        ? {}
        : { image: { width: rendered.width, height: rendered.height, color: rendered.color } })
    }
    return {
      preview,
      ...(rendered === undefined ? {} : { image: rendered.image }),
      ...(imageFailed ? { imageFailed } : {})
    }
  }

  const paths = (key: string): { readonly record: string; readonly image: string } => {
    const name = createHash("sha256").update(key).digest("hex")
    return { record: join(options.dir, `${name}.json`), image: join(options.dir, `${name}.img`) }
  }

  const readCache = async (
    key: string
  ): Promise<(Entry & { readonly fetchedAt: number }) | undefined> => {
    const files = paths(key)
    try {
      const record = Schema.decodeUnknownSync(CacheRecord)(
        JSON.parse(await readFile(files.record, "utf8"))
      )
      let image: LinkPreviewImage | undefined
      if (record.contentType !== undefined) {
        image = {
          contentType: record.contentType,
          data: new Uint8Array(await readFile(files.image))
        }
      }
      return {
        fetchedAt: record.fetchedAt,
        ...(record.preview === undefined ? {} : { preview: record.preview }),
        ...(image === undefined ? {} : { image }),
        ...(record.imageFailed === true ? { imageFailed: true } : {})
      }
    } catch {
      return undefined
    }
  }

  const writeCache = async (key: string, entry: Entry): Promise<void> => {
    const files = paths(key)
    const record: CacheRecord = {
      key,
      fetchedAt: now(),
      ...(entry.preview === undefined ? {} : { preview: entry.preview }),
      ...(entry.image === undefined ? {} : { contentType: entry.image.contentType }),
      ...(entry.imageFailed === true ? { imageFailed: true } : {})
    }
    try {
      await mkdir(options.dir, { recursive: true })
      if (entry.image !== undefined) {
        await writeFile(`${files.image}.tmp`, entry.image.data)
        await rename(`${files.image}.tmp`, files.image)
      }
      await writeFile(`${files.record}.tmp`, JSON.stringify(record))
      await rename(`${files.record}.tmp`, files.record)
    } catch {}
  }

  const cached = async (url: string): Promise<Entry | undefined> => {
    const key = `preview:${url}`
    const refresh = (): Promise<Entry | undefined> => {
      const running = inFlight.get(key)
      if (running !== undefined) return running
      const task = resolve(url)
        .then(async (entry) => {
          if (entry !== undefined) await writeCache(key, entry)
          return entry
        })
        .finally(() => inFlight.delete(key))
      inFlight.set(key, task)
      return task
    }
    const entry = await readCache(key)
    if (entry === undefined) return refresh()
    const age = now() - entry.fetchedAt
    if (entry.preview === undefined) {
      if (age < MISS_TTL_MS) return entry
      return refresh()
    }
    if (age >= (entry.imageFailed === true ? MISS_TTL_MS : HIT_TTL_MS)) background(refresh())
    return entry
  }

  const load = async (raw: string): Promise<Entry | undefined> => {
    const url = normalizePreviewUrl(raw)
    if (url === undefined) return undefined
    return cached(url)
  }

  return {
    preview: async (url) => (await load(url))?.preview,
    image: async (url) => (await load(url))?.image
  }
}
