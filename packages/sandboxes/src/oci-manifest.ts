import { Schema } from "effect"

export type ManifestFetch = (
  url: string,
  headers: Readonly<Record<string, string>>
) => Promise<Response>

interface ImageRef {
  readonly registry: string
  readonly repository: string
  readonly reference: string
}

const Layer = Schema.Struct({
  mediaType: Schema.String,
  size: Schema.Number,
  annotations: Schema.optional(Schema.Record(Schema.String, Schema.String))
})
type Layer = typeof Layer.Type

const decodeManifest = Schema.decodeUnknownSync(
  Schema.fromJsonString(Schema.Struct({ layers: Schema.Array(Layer) }))
)
const decodeToken = Schema.decodeUnknownSync(
  Schema.fromJsonString(
    Schema.Struct({
      token: Schema.optional(Schema.String),
      access_token: Schema.optional(Schema.String)
    })
  )
)

const manifestAccept = "application/vnd.oci.image.manifest.v1+json"
const uncompressedSizeKey = "org.cirruslabs.tart.uncompressed-size"
const contentDigestKey = "org.cirruslabs.tart.uncompressed-content-digest"

export const isRegistryImage = (image: string): boolean => parseImageRef(image) !== undefined

export const imageDiskBytes = async (
  image: string,
  fetchFn: ManifestFetch
): Promise<number | undefined> => {
  const ref = parseImageRef(image)
  if (ref === undefined) return undefined
  try {
    return diskBytes(decodeManifest(await manifestText(ref, fetchFn)).layers)
  } catch {
    return undefined
  }
}

const parseImageRef = (image: string): ImageRef | undefined => {
  const slash = image.indexOf("/")
  if (slash < 0) return undefined
  const registry = image.slice(0, slash)
  if (!/[.:]/.test(registry) && registry !== "localhost") return undefined

  const path = image.slice(slash + 1)
  const separator = path.includes("@") ? path.indexOf("@") : path.lastIndexOf(":")
  if (separator < 0) return { registry, repository: path, reference: "latest" }
  return { registry, repository: path.slice(0, separator), reference: path.slice(separator + 1) }
}

const manifestText = async (ref: ImageRef, fetchFn: ManifestFetch): Promise<string> => {
  const url = `https://${ref.registry}/v2/${ref.repository}/manifests/${ref.reference}`
  const anonymous = await fetchFn(url, { accept: manifestAccept })
  if (anonymous.status !== 401) return okText(anonymous)

  const token = await bearerToken(anonymous.headers.get("www-authenticate"), fetchFn)
  return okText(await fetchFn(url, { accept: manifestAccept, authorization: `Bearer ${token}` }))
}

const bearerToken = async (challenge: string | null, fetchFn: ManifestFetch): Promise<string> => {
  const parameters = Object.fromEntries(
    [...(challenge ?? "").matchAll(/(\w+)="([^"]*)"/g)].map(([, key, value]) => [key, value])
  )
  const realm = parameters["realm"]
  if (realm === undefined) throw new Error("The registry didn't say how to sign in")

  const query = new URLSearchParams()
  for (const key of ["service", "scope"]) {
    const value = parameters[key]
    if (value !== undefined) query.set(key, value)
  }
  const reply = decodeToken(await okText(await fetchFn(`${realm}?${query.toString()}`, {})))
  const token = reply.token ?? reply.access_token
  if (token === undefined) throw new Error("The registry didn't hand out a token")
  return token
}

const okText = async (response: Response): Promise<string> => {
  if (!response.ok) throw new Error(`HTTP ${String(response.status)}`)
  return response.text()
}

const diskBytes = (layers: ReadonlyArray<Layer>): number | undefined => {
  const disk = layers.filter((layer) => layer.mediaType.includes(".disk."))
  if (disk.length === 0) return undefined

  const repeated = repeatedDigests(disk)
  return disk.reduce((total, layer) => total + storedBytes(layer, repeated), 0)
}

const repeatedDigests = (layers: ReadonlyArray<Layer>): ReadonlySet<string | undefined> => {
  const seen = new Set<string>()
  const repeated = new Set<string | undefined>()
  for (const digest of layers.flatMap((layer) => layer.annotations?.[contentDigestKey] ?? [])) {
    if (seen.has(digest)) repeated.add(digest)
    seen.add(digest)
  }
  return repeated
}

const storedBytes = (layer: Layer, repeated: ReadonlySet<string | undefined>): number => {
  const uncompressed = Number(layer.annotations?.[uncompressedSizeKey])
  if (!Number.isFinite(uncompressed)) return layer.size

  return repeated.has(layer.annotations?.[contentDigestKey]) ? 0 : uncompressed
}
