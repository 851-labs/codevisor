import { WATCH_FACING, type StrapHalf, type WatchOnWrist } from "../../src/animations/waiting.js"
import { palette } from "../../src/color/palette.js"
import { handsetColor } from "../../src/effects/handset.js"
import {
  lightAngle,
  secondsAngle,
  strapSvg,
  WATCH_STEEL,
  watchLayers,
  WRISTWATCH,
  type WatchSpin
} from "../../src/effects/watch.js"
import type { BotMascotConfig } from "../../src/index.js"
import { collect, defsOf, paintsOf, type Item } from "./collect.js"
import { emitItems, f, newId } from "./emit.js"
import { parseSvg, pathContours } from "./svg.js"
import { add, heldObjects, keyVertex, type Tracks } from "./tracks.js"

export interface WatchIds {
  readonly node: string
  readonly face: string
  readonly straps: ReadonlyArray<ReadonlyArray<string>>
  readonly light: ReadonlyArray<string>
  readonly seconds: ReadonlyArray<string>
}

export interface WatchRig {
  readonly xml: string
  readonly ids: WatchIds
}

const REFERENCE_STRAP: ReadonlyArray<StrapHalf> = [
  {
    corners: [
      [0, 0],
      [10, -4],
      [18, -4],
      [24, 0]
    ],
    shaded: true
  },
  {
    corners: [
      [0, 0],
      [10, 4],
      [18, 4],
      [24, 0]
    ],
    shaded: false
  }
]

export function watchItems(config: BotMascotConfig): Item[] {
  const color = config.color ?? "sunny"
  const layers = layersFor(color)
  return [
    ...REFERENCE_STRAP.flatMap((half) => itemsOf(strapOf(half, color))),
    ...itemsOf(layers.back),
    ...layers.front.flatMap((layer) => itemsOf(layer.svg))
  ]
}

export function watchRig(bind: (paintIndex: number) => string): WatchRig {
  const color = "sunny"
  const layers = layersFor(color)
  let used = 0
  const emitted = (items: Item[]) => {
    const offset = used
    used += paintsOf(items).length
    return emitItems(items, { bind: (i) => bind(i + offset) })
  }
  const straps = REFERENCE_STRAP.map((half) => emitted(itemsOf(strapOf(half, color))))
  const back = emitted(itemsOf(layers.back))
  const light: Array<string> = []
  const seconds: Array<string> = []
  const front = layers.front.map((layer) => {
    const rml = emitted(itemsOf(layer.svg)).rml
    const spun = spinList(layer.spin, light, seconds)
    if (!spun) return rml
    const id = newId()
    spun.push(id)
    return `<Node name="${layer.spin}" id="${id}">${rml}</Node>`
  })
  const node = newId()
  const face = newId()
  for (const id of seconds) heldObjects.add(id)
  const xml = `<Node opacity="0" name="Watch" id="${node}">
<Node name="Watch face" id="${face}">
<Node scaleY="${f(WATCH_FACING)}" name="Front" id="${newId()}">${front.toReversed().join("\n")}</Node>
${back.rml}
</Node>
${straps
  .map((s) => s.rml)
  .toReversed()
  .join("\n")}
</Node>`
  return {
    xml,
    ids: { node, face, straps: straps.map((s) => s.ids[0].vertices[0]), light, seconds }
  }
}

export function keyWatch(
  tracks: Tracks,
  ids: WatchIds,
  watch: WatchOnWrist | null,
  clock: number,
  frame: number
) {
  add(tracks, ids.node, "opacity", frame, watch ? 1 : 0)
  if (!watch) return
  add(tracks, ids.node, "scaleX", frame, watch.pop)
  add(tracks, ids.node, "scaleY", frame, watch.pop)
  add(tracks, ids.node, "x", frame, watch.at[0] * (1 - watch.pop))
  add(tracks, ids.node, "y", frame, watch.at[1] * (1 - watch.pop))
  add(tracks, ids.face, "x", frame, watch.face[0])
  add(tracks, ids.face, "y", frame, watch.face[1])
  add(tracks, ids.face, "rotation", frame, watch.turn)
  for (const id of ids.light)
    add(tracks, id, "rotation", frame, lightAngle(watch.turn, WATCH_FACING))
  for (const id of ids.seconds) add(tracks, id, "rotation", frame, secondsAngle(clock))
  watch.halves.forEach((half, k) => keyStrap(tracks, ids.straps[k] ?? [], half, k))
  function keyStrap(t: Tracks, vertexIds: ReadonlyArray<string>, half: StrapHalf, k: number) {
    if (half.shaded !== REFERENCE_STRAP[k]?.shaded)
      throw new Error(`strap half ${k} changed its shading at frame ${frame}`)
    const vertices = pathContours(strapPath(half))[0]?.vertices ?? []
    vertices.forEach((v, i) => keyVertex(t, vertexIds[i], v, frame))
  }
}

function layersFor(color: string) {
  return watchLayers({
    radius: WRISTWATCH.radius,
    rim: WRISTWATCH.rim,
    metal: WATCH_STEEL,
    outline: palette(color).outline,
    facing: WATCH_FACING
  })
}

const strapOf = (half: StrapHalf, color: string): string => {
  const P = palette(color)
  return strapSvg(half.corners, handsetColor(P.key), P.outline, half.shaded)
}

const strapPath = (half: StrapHalf): string =>
  /d="([^"]+)"/.exec(strapSvg(half.corners, "#000000", "#000000", half.shaded))?.[1] ?? ""

function itemsOf(svg: string): Item[] {
  const root = parseSvg(`<svg>${svg}</svg>`)
  return collect(root, defsOf(root))
}

function spinList(
  spin: WatchSpin,
  light: Array<string>,
  seconds: Array<string>
): Array<string> | null {
  if (spin === "toward the light") return light
  if (spin === "with the seconds") return seconds
  return null
}
