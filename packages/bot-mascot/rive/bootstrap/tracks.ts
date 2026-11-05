import { f, handle } from "./emit.js"
import type { Vertex } from "./svg.js"

export type Key = [number, number | string]
export type Tracks = Map<string, Map<string, Array<Key>>>

export const heldObjects = new Set<string>()

export const add = (
  tracks: Tracks,
  obj: string,
  property: string,
  frame: number,
  value: number | string
) => {
  if (!tracks.has(obj)) tracks.set(obj, new Map())
  const t = tracks.get(obj)!
  if (!t.has(property)) t.set(property, [])
  const keys = t.get(property)!
  keys.push([frame, unwrapped(property, keys[keys.length - 1]?.[1], value)])
}

const unwrapped = (
  property: string,
  previous: number | string | undefined,
  value: number | string
) => {
  if (!property.endsWith("otation") || typeof value !== "number" || typeof previous !== "number")
    return value
  return value + 2 * Math.PI * Math.round((previous - value) / (2 * Math.PI))
}

export function keyVertex(tracks: Tracks, vid: string | undefined, v: Vertex, frame: number) {
  if (!vid) return
  add(tracks, vid, "x", frame, v.p[0])
  add(tracks, vid, "y", frame, v.p[1])
  if (!v.inH && !v.outH) return
  const [ir, id_] = handle(v, v.inH)
  const [or, od] = handle(v, v.outH)
  add(tracks, vid, "inRotation", frame, ir)
  add(tracks, vid, "inDistance", frame, id_)
  add(tracks, vid, "outRotation", frame, or)
  add(tracks, vid, "outDistance", frame, od)
}

export function tracksXml(tracks: Tracks): string {
  return [...tracks]
    .map(([obj, props]) => {
      const keyed = [...props]
        .map(([p, keys]) => propertyXml(p, keys, heldObjects.has(obj)))
        .join("")
      return `<KeyedObject objectId="${obj}">${keyed}</KeyedObject>`
    })
    .join("")
}

function propertyXml(property: string, keys: ReadonlyArray<Key>, held: boolean): string {
  const hold = held || isToggle(property, keys)
  const kept = hold ? changesOnly(keys) : thinned(property, keys)
  const xml = kept.map(([frame, v]) => keyFrameXml(property, frame, v, hold))
  return `<KeyedProperty property="${property}">${xml.join("")}</KeyedProperty>`
}

const isToggle = (property: string, keys: ReadonlyArray<Key>): boolean =>
  property === "opacity" && keys.every(([, v]) => v === 0 || v === 1)

const isLength = (property: string): boolean =>
  property === "x" || property === "y" || property.endsWith("Distance")

const keyFrameXml = (property: string, frame: number, v: number | string, hold: boolean): string =>
  typeof v === "string"
    ? `<KeyFrameId value="${v}" frame="${frame}" interpolationType="hold"/>`
    : `<KeyFrameDouble value="${valueText(property, v)}" frame="${frame}" interpolationType="${hold ? "hold" : "linear"}"/>`

const valueText = (property: string, v: number): string =>
  isLength(property) ? f(Math.round(v * 1000) / 1000) : f(v)

const tolerance = (property: string): number => {
  if (isLength(property)) return 0.04
  if (property === "thickness") return 0.01
  return 0.0004
}

function thinned(property: string, keys: ReadonlyArray<Key>): ReadonlyArray<Key> {
  if (keys.length < 3) return keys
  if (keys.some(([, v]) => typeof v === "string")) return changesOnly(keys)
  const numeric = keys.map(([fr, v]): [number, number] => [fr, Number(v)])
  return linearlyThinned(numeric, tolerance(property))
}

const changesOnly = (keys: ReadonlyArray<Key>): ReadonlyArray<Key> =>
  keys.filter((k, i) => i === 0 || k[1] !== keys[i - 1][1])

function linearlyThinned(
  keys: ReadonlyArray<[number, number]>,
  tol: number
): Array<[number, number]> {
  const kept: Array<[number, number]> = [keys[0]]
  let anchor = 0
  for (let i = 2; i < keys.length; i++) {
    if (spanFits(keys, anchor, i, tol)) continue
    kept.push(keys[i - 1])
    anchor = i - 1
  }
  kept.push(keys[keys.length - 1])
  return kept
}

function spanFits(
  keys: ReadonlyArray<[number, number]>,
  from: number,
  to: number,
  tol: number
): boolean {
  const [f0, v0] = keys[from]
  const [f1, v1] = keys[to]
  for (let k = from + 1; k < to; k++) {
    const [fk, vk] = keys[k]
    if (Math.abs(v0 + ((v1 - v0) * (fk - f0)) / (f1 - f0) - vk) > tol) return false
  }
  return true
}
