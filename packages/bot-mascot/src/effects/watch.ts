import { CREAM, mix } from "../color/colors.js"
import { f2, normalize, pointText, TAU, type Point } from "../geometry/math.js"
import { LIGHT } from "../render/frame.js"

export interface WatchFace {
  readonly radius: number
  readonly rim: number
  readonly metal: string
  readonly outline: string
  readonly turn: number
  readonly facing: number
  readonly seconds: number
}

export type WatchSpin = "with the watch" | "toward the light" | "with the seconds"

export interface WatchLayer {
  readonly svg: string
  readonly spin: WatchSpin
}

export interface WatchLayers {
  readonly back: string
  readonly front: ReadonlyArray<WatchLayer>
}

export type WatchLook = Omit<WatchFace, "turn" | "seconds">

export const WATCH_STEEL = "#D5DAE4"
export const WRISTWATCH = { radius: 14, rim: 3.4, strap: 18 } as const

const LINE = 4.5
const SHADE_NUDGE = 0.2
const GLARE_SPAN = 0.42
const TEN_PAST_TEN = { hour: (-60 * Math.PI) / 180, minute: (60 * Math.PI) / 180 }
const ARC_STEPS = 20
const CASE_DEPTH = 9
const STRAP_SHADE = 0.2
const SECOND_HAND = "#E5484D"

export function watchFaceSvg(face: WatchFace): string {
  const { radius, rim, metal, outline, facing } = face
  const dial = radius - rim
  const toLight = lightOnTurned(face.turn, facing)
  const front =
    `<circle r="${f2(radius)}" fill="${metal}"/>` +
    shadeBand(radius, toLight, mix(metal, "#000000", 0.24)) +
    `<circle r="${f2(dial)}" fill="${CREAM}" stroke="${outline}" stroke-width="${f2(LINE * 0.45)}"/>` +
    shadeBand(dial, toLight, mix(CREAM, "#1B2140", 0.16)) +
    hourMarks(dial, outline) +
    hands(dial, outline, face.seconds) +
    glare(dial, toLight)
  return caseSvg(face) + `<g transform="scale(1 ${f2(facing)})">${front}</g>`
}

export function watchLayers(look: WatchLook): WatchLayers {
  const { radius, rim, metal, outline } = look
  const dial = radius - rim
  const east: Point = [1, 0]
  return {
    back: caseSvg(look),
    front: [
      layer(`<circle r="${f2(radius)}" fill="${metal}"/>`),
      layer(shadeBand(radius, east, mix(metal, "#000000", 0.24)), "toward the light"),
      layer(
        `<circle r="${f2(dial)}" fill="${CREAM}" stroke="${outline}" stroke-width="${f2(LINE * 0.45)}"/>`
      ),
      layer(shadeBand(dial, east, mix(CREAM, "#1B2140", 0.16)), "toward the light"),
      layer(hourMarks(dial, outline)),
      layer(hand(0, dial * 0.78, dial * 0.07, SECOND_HAND), "with the seconds"),
      layer(hand(TEN_PAST_TEN.hour, dial * 0.5, dial * 0.2, outline)),
      layer(hand(TEN_PAST_TEN.minute, dial * 0.74, dial * 0.16, outline)),
      layer(`<circle r="${f2(dial * 0.14)}" fill="${outline}"/>`),
      layer(glare(dial, east), "toward the light")
    ]
  }
}

const layer = (svg: string, spin: WatchSpin = "with the watch"): WatchLayer => ({ svg, spin })

export function lightAngle(turn: number, facing: number): number {
  const [x, y] = lightOnTurned(turn, facing)
  return Math.atan2(y, x)
}

export const secondsAngle = (seconds: number): number => (Math.floor(seconds) / 60) * TAU

export const strapShade = (color: string): string => mix(color, "#000000", STRAP_SHADE)

export function strapSvg(
  corners: ReadonlyArray<Point>,
  color: string,
  outline: string,
  shaded: boolean
): string {
  const d = `M${corners.map(pointText).join("L")}Z`
  const fill = shaded ? strapShade(color) : color
  return `<path d="${d}" fill="${fill}" stroke="${outline}" stroke-width="${LINE}" stroke-linejoin="round"/>`
}

export function lightIn(turn: number): Point {
  const [x, y] = normalize(LIGHT)
  const c = Math.cos(-turn)
  const s = Math.sin(-turn)
  return [x * c - y * s, x * s + y * c]
}

function lightOnTurned(turn: number, facing: number): Point {
  const [x, y] = lightIn(turn)
  return normalize([x, y / facing])
}

function caseSvg({ radius, metal, outline, facing }: WatchLook): string {
  const deep = CASE_DEPTH * (1 - facing)
  const puck = (grow: number, fill: string): string => {
    const rx = radius + grow
    const ry = radius * facing + grow
    return (
      `<ellipse cy="${f2(deep)}" rx="${f2(rx)}" ry="${f2(ry)}" fill="${fill}"/>` +
      `<rect x="${f2(-rx)}" width="${f2(2 * rx)}" height="${f2(deep)}" fill="${fill}"/>` +
      `<ellipse rx="${f2(rx)}" ry="${f2(ry)}" fill="${fill}"/>`
    )
  }
  return puck(LINE, outline) + puck(0, mix(metal, "#000000", 0.3))
}

function shadeBand(radius: number, toLight: Point, color: string): string {
  const facing = Math.atan2(toLight[1], toLight[0])
  const nudge = SHADE_NUDGE * radius
  const half = Math.acos(nudge / (2 * radius))
  const away = arc([0, 0], radius, facing + half, facing + TAU - half)
  const lit: Point = [toLight[0] * nudge, toLight[1] * nudge]
  const back = arc(lit, radius, facing + Math.PI + half, facing + Math.PI - half)
  return `<path d="M${[...away, ...back].map(pointText).join("L")}Z" fill="${color}"/>`
}

function arc(centre: Point, radius: number, from: number, to: number): ReadonlyArray<Point> {
  return Array.from({ length: ARC_STEPS + 1 }, (_, i): Point => {
    const a = from + ((to - from) * i) / ARC_STEPS
    return [centre[0] + radius * Math.cos(a), centre[1] + radius * Math.sin(a)]
  })
}

function hourMarks(dial: number, outline: string): string {
  const mark = (quarter: number): string => {
    const a = (quarter * Math.PI) / 2
    const [x, y] = [Math.sin(a), -Math.cos(a)]
    return `M${f2(x * dial * 0.7)} ${f2(y * dial * 0.7)}L${f2(x * dial * 0.84)} ${f2(y * dial * 0.84)}`
  }
  const d = [0, 1, 2, 3].map(mark).join("")
  return `<path d="${d}" fill="none" stroke="${outline}" stroke-width="${f2(dial * 0.11)}" stroke-linecap="round" opacity=".55"/>`
}

function hands(dial: number, outline: string, seconds: number): string {
  return (
    hand(secondsAngle(seconds), dial * 0.78, dial * 0.07, SECOND_HAND) +
    hand(TEN_PAST_TEN.hour, dial * 0.5, dial * 0.2, outline) +
    hand(TEN_PAST_TEN.minute, dial * 0.74, dial * 0.16, outline) +
    `<circle r="${f2(dial * 0.14)}" fill="${outline}"/>`
  )
}

const hand = (angle: number, length: number, width: number, color: string): string =>
  `<path d="M0 0L${f2(Math.sin(angle) * length)} ${f2(-Math.cos(angle) * length)}" fill="none" stroke="${color}" stroke-width="${f2(width)}" stroke-linecap="round"/>`

function glare(dial: number, toLight: Point): string {
  const facing = Math.atan2(toLight[1], toLight[0])
  const streak = arc([0, 0], dial * 0.72, facing - GLARE_SPAN, facing + GLARE_SPAN)
  const dot = arc([0, 0], dial * 0.72, facing + GLARE_SPAN + 0.34, facing + GLARE_SPAN + 0.34)[0]!
  return (
    `<path d="M${streak.map(pointText).join("L")}" fill="none" stroke="#fff" stroke-opacity=".92" stroke-width="${f2(dial * 0.15)}" stroke-linecap="round"/>` +
    `<circle cx="${f2(dot[0])}" cy="${f2(dot[1])}" r="${f2(dial * 0.07)}" fill="#fff" fill-opacity=".92"/>`
  )
}
