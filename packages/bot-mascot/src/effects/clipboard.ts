import type { Palette } from "../color/palette.js"
import { bump, f2, s01, TAU } from "../geometry/math.js"
import { lidAt } from "../moods/timing.js"
import type { BotMascotPose, ClipboardEffect } from "../pose.js"
import type { RenderContext } from "../render/context.js"
import {
  clipboardGaze,
  clipboardLines,
  flipAngle,
  FLIP_DOWN,
  FLIP_UP,
  type ReadingLine
} from "./clipboard-reading.js"

export const CLIPBOARD_POP = 0.4
export const CLIPBOARD_LOOP = 12

const NODS = [1.6, 3.2, 5.6, 9.4, 10.9]
const BOARD = { x0: 210, x1: 290, y0: 318, y1: 382 }
const PAGE = 56
const REST = [294, 366, -64] as const
const OUT = [322, 334, -40] as const
const GRIP = -18

type Triple = readonly [number, number, number]

interface FlipHand {
  readonly x: number
  readonly y: number
  readonly rot: number
  readonly behind: boolean
}

const lines = clipboardLines()
const slowLine = lines.find((l) => l.slow)!
const blinks = [lineEnd(lines[0]!), lineEnd(lines[4]!), lineEnd(lines[6]!)]

export function clipboardPose(t: number): BotMascotPose {
  const tt = clipboardTime(t)
  const c = Math.cos((flipAngle(tt) * Math.PI) / 180)
  const th = flipAngle(tt)
  const nod = nodOf(tt)
  const above = th > 90 && th < 270 ? -c : 0
  const g = clipboardGaze(lines, tt)
  const q = concern(tt)
  const q2 = recheck(tt)
  const sq = Math.max(q, q2)
  return {
    sy: 1 + 0.012 * Math.sin((TAU * t) / 1.8) - 0.025 * nod,
    y: -1.5 * nod,
    tilt: 2 * nod + 1.5 * Math.sin((TAU * t) / 6) - 3 * q - 1.5 * q2,
    shift: 3 * q + 1.5 * q2,
    face: {
      turn: g.turn * (1 - 0.6 * above),
      up: g.up + 0.06 * nod + 0.08 * sq - 0.5 * above,
      blink: Math.min(1 - 0.4 * sq, lidAt(tt, 0.15, ...blinks)),
      mode: "open"
    },
    fx: [{ kind: "clipboard", tt, pop: t < CLIPBOARD_POP ? t / CLIPBOARD_POP : 1, nod, op: 1 }]
  }
}

export const clipboardPopScale = (pop: number): number =>
  pop < 1 ? Math.min(1.18, s01(pop / 0.7) * 1.18) - 0.18 * s01((pop - 0.7) / 0.3) : 1

export function clipboardSvg(
  ctx: RenderContext,
  P: Palette,
  f: ClipboardEffect,
  lift: number
): string {
  const O = P.outline
  const { tt, pop } = f
  const k = clipboardPopScale(pop)
  const ny = 1.5 * f.nod - lift
  const cx = 250
  const cy = (BOARD.y0 + BOARD.y1) / 2
  const clipTop = `<rect x="238" y="${BOARD.y0 - 7}" width="24" height="9" rx="3.5" fill="#AEB4C0" stroke="${O}" stroke-width="4"/>`
  const lit = `${ctx.idPrefix}cbs${++ctx.ids.clipboard}`
  const board = boardSvg(O, lit)
  const py = BOARD.y0 - 9
  const len = PAGE + 12
  const page = pageSvg(O, lit, flipAngle(tt), py, len)
  const hl = ctx.hands(P, { pose: "open", x: 206, y: 366, rot: 64, s: 0.72, mirror: true })
  const hr = flipHand(tt, py, len)
  const hrSvg = ctx.hands(P, { pose: "open", x: hr.x, y: hr.y, rot: hr.rot, s: 0.72 })
  const back = hr.behind ? hrSvg : ""
  const front = hr.behind ? "" : hrSvg
  if (pop <= 0.02) return ""
  const g = (inner: string): string =>
    `<g transform="translate(${cx} ${f2(cy + ny)}) scale(${f2(k)}) translate(${-cx} ${-cy})">${inner}</g>`
  return (
    g(back + board + clipTop + page + front) + `<g transform="translate(0 ${f2(ny)})">${hl}</g>`
  )
}

function clipboardTime(t: number): number {
  return t < CLIPBOARD_POP ? 0 : (t - CLIPBOARD_POP) % CLIPBOARD_LOOP
}

function lineEnd(l: ReadingLine): number {
  return l.a + l.sw + 0.01
}

function nodOf(tt: number): number {
  return NODS.reduce((a, k) => a + bump((tt - k) / 0.45), 0)
}

function concern(tt: number): number {
  return (
    s01((tt - (slowLine.a + 0.35 * slowLine.sw)) / 0.35) * (1 - s01((tt - slowLine.end) / 0.22))
  )
}

function recheck(tt: number): number {
  return s01((tt - 5.0) / 0.35) * (1 - s01((tt - 6.7) / 0.3))
}

const shade = (lit: string, d: string): string => `<path d="${d}" fill="url(#${lit}s)"/>`

function roundedRect(x: number, y: number, w: number, h: number, r: number): string {
  return `M${x + r} ${y}H${x + w - r}Q${x + w} ${y} ${x + w} ${y + r}V${y + h - r}Q${x + w} ${y + h} ${x + w - r} ${y + h}H${x + r}Q${x} ${y + h} ${x} ${y + h - r}V${y + r}Q${x} ${y} ${x + r} ${y}Z`
}

function boardSvg(O: string, lit: string): string {
  const { x0, x1, y0, y1 } = BOARD
  return (
    `<defs><linearGradient id="${lit}s" x1=".8" y1="0" x2=".2" y2="1"><stop offset=".35" stop-color="#1B2140" stop-opacity="0"/><stop offset="1" stop-color="#1B2140" stop-opacity=".16"/></linearGradient></defs>` +
    `<rect x="${x0}" y="${y0}" width="${x1 - x0}" height="${y1 - y0}" rx="7" fill="#B98048" stroke="${O}" stroke-width="6"/>` +
    `<rect x="${x0 + 8}" y="${y0 + 8}" width="${x1 - x0 - 16}" height="${y1 - y0 - 16}" rx="4" fill="#A9733F"/>` +
    shade(lit, roundedRect(x0, y0, x1 - x0, y1 - y0, 7))
  )
}

function pageSvg(O: string, lit: string, th: number, py: number, len: number): string {
  if (th <= 90) return ""
  const c = Math.cos((th * Math.PI) / 180)
  const x0 = BOARD.x0 + 5
  const x1 = BOARD.x1 - 5
  const y1 = py + len * c
  const d = c >= 0 ? risingPage(x0, x1, py, y1, c) : hangingPage(x0, x1, py, y1)
  const fold =
    c >= 0
      ? `<path d="M${x0 + 3} ${f2(py + 3)}Q250 ${f2(py - 2)} ${x1 - 3} ${f2(py + 3)}" fill="none" stroke="#1B2140" stroke-opacity=".12" stroke-width="4" stroke-linecap="round"/>`
      : ""
  const dim =
    Math.abs(c) < 0.98
      ? `<path d="${d}" fill="#1B2140" opacity="${f2(0.12 * (1 - Math.abs(c)))}"/>`
      : ""
  return (
    `<path d="${d}" fill="#FBF8F1" stroke="${O}" stroke-width="3" stroke-linejoin="round"/>` +
    shade(lit, d) +
    fold +
    dim
  )
}

function risingPage(x0: number, x1: number, py: number, y1: number, c: number): string {
  const r = 7 * (0.4 + 0.6 * c)
  return `M${x0} ${f2(y1)}L${x0} ${py}C${x0} ${f2(py - r * 1.35)} ${x1} ${f2(py - r * 1.35)} ${x1} ${py}L${x1} ${f2(y1)}Z`
}

function hangingPage(x0: number, x1: number, py: number, y1: number): string {
  return `M${x0} ${py}L${x0} ${f2(y1 + 6)}Q${x0} ${f2(y1)} ${x0 + 6} ${f2(y1)}L${x1 - 6} ${f2(y1)}Q${x1} ${f2(y1)} ${x1} ${f2(y1 + 6)}L${x1} ${py}Z`
}

const lerp3 = (a: Triple, b: Triple, u: number): Triple => [
  a[0] + (b[0] - a[0]) * u,
  a[1] + (b[1] - a[1]) * u,
  a[2] + (b[2] - a[2]) * u
]

const handAt = (p: Triple, behind: boolean): FlipHand => ({ x: p[0], y: p[1], rot: p[2], behind })

function pageEdge(th: number, py: number, len: number, corner: Triple): Triple {
  const c = Math.cos((th * Math.PI) / 180)
  const y1 = py + len * c
  const rot = GRIP + 8 * s01((th - 150) / 60)
  return th <= 180 ? [279, Math.min(corner[1], y1 - 6), rot] : [279, y1 - 6, rot]
}

function flipHand(tt: number, py: number, len: number): FlipHand {
  const corner: Triple = [282, py + 8, GRIP]
  const edge = (th: number): Triple => pageEdge(th, py, len, corner)
  const [u0, du] = FLIP_UP
  const [d0, dd] = FLIP_DOWN
  if (tt >= u0 - 0.5 && tt < u0)
    return reachRound(REST, OUT, corner, (tt - (u0 - 0.5)) / 0.5, false)
  if (tt >= u0 && tt < u0 + du) return riding(edge, flipAngle(tt))
  if (tt >= u0 + du && tt < u0 + du + 0.35)
    return handAt(lerp3(edge(360), REST, s01((tt - u0 - du) / 0.35)), false)
  if (tt >= d0 - 0.4 && tt < d0)
    return handAt(lerp3(REST, edge(360), s01((tt - (d0 - 0.4)) / 0.4)), false)
  if (tt >= d0 && tt < d0 + dd) return riding(edge, flipAngle(tt))
  if (tt >= d0 + dd && tt < d0 + dd + 0.5)
    return reachRound(corner, OUT, REST, (tt - d0 - dd) / 0.5, true)
  return handAt(REST, false)
}

function riding(edge: (th: number) => Triple, th: number): FlipHand {
  return handAt(edge(th), th <= 180)
}

function reachRound(
  from: Triple,
  via: Triple,
  to: Triple,
  u: number,
  startsBehind: boolean
): FlipHand {
  if (u < 0.5) return handAt(lerp3(from, via, s01(u / 0.5)), startsBehind)
  return handAt(lerp3(via, to, s01((u - 0.5) / 0.5)), !startsBehind)
}
