import {
  botMascotColors,
  botMascotEyewear,
  botMascotHats,
  botMascotOutfits,
  botMascotSwatches,
  type ResolvedBotMascotConfig,
  type SwatchChoice
} from "@codevisor/bot-mascot"

import { animations } from "./animations.js"
import {
  armLayers,
  armModes,
  armProps,
  backdrops,
  defaultState,
  frameOf,
  frameRates,
  speeds,
  type ArmControls,
  type ArmSide,
  type Overlays,
  type PlaygroundState,
  type RigControls
} from "./state.js"
import { leafText, leaves, UrlReader } from "./url-reader.js"

type Look = ResolvedBotMascotConfig

const frameKey = "frame"
const unsharedKeys: ReadonlySet<string> = new Set(["time", "playing"])

export function stateToSearch(state: PlaygroundState): string {
  const defaults = new Map(leaves(defaultState))
  const params = new URLSearchParams()
  for (const [path, value] of leaves(state)) {
    if (isShared(path) && defaults.get(path) !== value) params.set(path, leafText(value))
  }
  if (!state.playing) params.set(frameKey, String(frameOf(state)))
  return params.toString()
}

export function stateFromSearch(search: string): PlaygroundState {
  const params = new URLSearchParams(search)
  const state = sharedState(new UrlReader(params))
  const frame = Number(params.get(frameKey) ?? Number.NaN)
  if (!Number.isFinite(frame)) return state

  return { ...state, playing: false, time: frame / state.fps }
}

const isShared = (path: string): boolean => !unsharedKeys.has(path)

const ids = <Id extends string>(list: ReadonlyArray<{ readonly id: Id }>): ReadonlyArray<Id> =>
  list.map((o) => o.id)

const swatchChoices: ReadonlyArray<SwatchChoice> = ["auto", ...ids(botMascotSwatches)]
const hats: ReadonlyArray<Look["hat"]> = ["none", ...ids(botMascotHats)]
const eyewear: ReadonlyArray<Look["eyewear"]> = ["none", ...ids(botMascotEyewear)]
const outfits: ReadonlyArray<Look["outfit"]> = ["none", ...ids(botMascotOutfits)]

const sharedState = (read: UrlReader): PlaygroundState => {
  const d = defaultState
  return {
    ...d,
    look: lookFrom(read, d.look),
    animation: read.choice("animation", ids(animations), d.animation),
    speed: read.numberFrom("speed", speeds, d.speed),
    loop: read.flag("loop", d.loop),
    fps: read.numberFrom("fps", frameRates, d.fps),
    backdrop: read.choice("backdrop", backdrops, d.backdrop),
    rig: rigFrom(read, d.rig)
  }
}

const lookFrom = (read: UrlReader, d: Look): Look => ({
  ...d,
  color: read.choice("look.color", ids(botMascotColors), d.color),
  hat: read.choice("look.hat", hats, d.hat),
  hatColor: read.choice("look.hatColor", swatchChoices, d.hatColor),
  eyewear: read.choice("look.eyewear", eyewear, d.eyewear),
  eyewearColor: read.choice("look.eyewearColor", swatchChoices, d.eyewearColor),
  outfit: read.choice("look.outfit", outfits, d.outfit),
  outfitColor: read.choice("look.outfitColor", swatchChoices, d.outfitColor),
  makeup: {
    blush: read.flag("look.makeup.blush", d.makeup.blush),
    freckles: read.flag("look.makeup.freckles", d.makeup.freckles),
    lashes: read.flag("look.makeup.lashes", d.makeup.lashes)
  },
  blushColor: read.choice("look.blushColor", swatchChoices, d.blushColor)
})

const rigFrom = (read: UrlReader, d: RigControls): RigControls => ({
  on: read.flag("rig.on", d.on),
  left: armFrom(read, "left", d.left),
  right: armFrom(read, "right", d.right),
  overlays: overlaysFrom(read, d.overlays)
})

const armFrom = (read: UrlReader, side: ArmSide, d: ArmControls): ArmControls => {
  const key = (field: keyof ArmControls) => `rig.${side}.${field}`
  return {
    on: read.flag(key("on"), d.on),
    mode: read.choice(key("mode"), armModes, d.mode),
    grow: read.number(key("grow"), d.grow),
    x: read.number(key("x"), d.x),
    y: read.number(key("y"), d.y),
    autoCurl: read.flag(key("autoCurl"), d.autoCurl),
    curl: read.number(key("curl"), d.curl),
    angle: read.number(key("angle"), d.angle),
    length: read.number(key("length"), d.length),
    bend: read.number(key("bend"), d.bend),
    prop: read.choice(key("prop"), armProps, d.prop),
    layer: read.choice(key("layer"), armLayers, d.layer)
  }
}

const overlaysFrom = (read: UrlReader, d: Overlays): Overlays => {
  const on = (name: keyof Overlays) => read.flag(`rig.overlays.${name}`, d[name])
  return {
    silhouette: on("silhouette"),
    edges: on("edges"),
    outline: on("outline"),
    points: on("points")
  }
}
