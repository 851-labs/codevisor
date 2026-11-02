import raw from "./data/bot-mascot-data.json" with { type: "json" }
import type { Point } from "./geometry/math.js"

export interface RawPalette {
  readonly title: string
  readonly note: string
  readonly body: ReadonlyArray<readonly [number, string]>
  readonly outline: string
  readonly eye: string
  readonly glint: string
  readonly cheek: string
  readonly shade: string
  readonly shadow: string
  readonly fx: string
}

export interface CyclopsData {
  readonly n: number
  readonly right: ReadonlyArray<number>
  readonly left: ReadonlyArray<number>
  readonly up: ReadonlyArray<number>
  readonly down: ReadonlyArray<number>
  readonly centre: ReadonlyArray<number>
  readonly width: number
  readonly y: number
  readonly radius: number
  readonly theta: number
  readonly nudge: Point
  readonly cheek: {
    readonly phi: number
    readonly y: number
    readonly rx: number
    readonly ry: number
  }
  readonly glint: {
    readonly light: number
    readonly parallax: number
    readonly main: number
    readonly along: number
    readonly bounce: number
    readonly bounce_along: number
  }
}

export interface BotMascotData {
  readonly body: string
  readonly hole: string
  readonly mark: { readonly left: string; readonly body: string; readonly hole: string }
  readonly eye: { readonly x: number; readonly y: number; readonly s: number }
  readonly feet: { readonly x: number; readonly y: number }
  readonly palettes: Readonly<Record<string, RawPalette>>
  readonly cyclops: CyclopsData
  readonly rig: {
    readonly points: ReadonlyArray<Point>
    readonly hip: { readonly L: Point; readonly R: Point }
    readonly waist: Point
    readonly centre: Point
  }
}

const point = (p: ReadonlyArray<number>): Point => [p[0]!, p[1]!]

const stop = (s: ReadonlyArray<number | string>): readonly [number, string] => [
  Number(s[0]),
  String(s[1])
]

const palettes = Object.fromEntries(
  Object.entries(raw.palettes).map(([key, p]) => [key, { ...p, body: p.body.map(stop) }])
)

export const data: BotMascotData = {
  ...raw,
  palettes,
  cyclops: { ...raw.cyclops, nudge: point(raw.cyclops.nudge) },
  rig: {
    points: raw.rig.points.map(point),
    hip: { L: point(raw.rig.hip.L), R: point(raw.rig.hip.R) },
    waist: point(raw.rig.waist),
    centre: point(raw.rig.centre)
  }
}
export const cyclops = data.cyclops
