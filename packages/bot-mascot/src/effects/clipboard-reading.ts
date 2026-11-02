import { s01, TAU } from "../geometry/math.js"

export interface ReadingLine {
  readonly a: number
  readonly sw: number
  readonly row: number
  readonly slow: boolean
  readonly end: number
}

export interface Gaze {
  readonly turn: number
  readonly up: number
}

export const FLIP_UP = [4.0, 0.7] as const
export const FLIP_DOWN = [7.4, 0.7] as const

const LEFT = 0.32
const RIGHT = -0.32
const RETURN = 0.12
const STRETCHES: ReadonlyArray<readonly [number, number, number, number]> = [
  [0, 3.75, 3, 2],
  [4.75, 7.3, 2, -1],
  [8.15, 12, 3, -1]
]

export function flipAngle(tt: number): number {
  const [upAt, upFor] = FLIP_UP
  const [downAt, downFor] = FLIP_DOWN
  if (tt < upAt) return 0
  if (tt < upAt + upFor) return 360 * s01((tt - upAt) / upFor)
  if (tt < downAt) return 360
  if (tt < downAt + downFor) return 360 * (1 - s01((tt - downAt) / downFor))
  return 0
}

export function clipboardLines(): ReadonlyArray<ReadingLine> {
  const lines: Array<ReadingLine> = []
  for (const [a, b, n, slow] of STRETCHES) {
    const w = Array.from({ length: n }, (_, k) => (k === slow ? 1.45 : 1))
    const unit = (b - a - n * RETURN) / w.reduce((x, y) => x + y, 0)
    let t = a
    for (let k = 0; k < n; k++) {
      const sw = w[k]! * unit
      lines.push({ a: t, sw, row: k, slow: k === slow, end: t + sw + RETURN })
      t += sw + RETURN
    }
  }
  return lines
}

export function clipboardGaze(lines: ReadonlyArray<ReadingLine>, tt: number): Gaze {
  let i = lines.length - 1
  while (i > 0 && tt < lines[i]!.a) i--
  const l = lines[i]!
  const u = tt - l.a
  if (u < 0) return { turn: LEFT, up: rowHeight(0) }
  if (u < l.sw)
    return { turn: LEFT + (RIGHT - LEFT) * readAlong(l, u / l.sw), up: rowHeight(l.row) }
  if (u < l.sw + RETURN) return carriageReturn(l, lines[i + 1], u)
  return { turn: LEFT, up: rowHeight(0) }
}

function rowHeight(row: number): number {
  return 0.24 + 0.06 * row
}

function readAlong(l: ReadingLine, v: number): number {
  return l.slow ? v + 0.075 * Math.sin(TAU * v) : 0.75 * v + 0.25 * s01(v)
}

function carriageReturn(l: ReadingLine, next: ReadingLine | undefined, u: number): Gaze {
  const r = s01((u - l.sw) / RETURN)
  const nextRow = next && next.a - l.end < 0.05 ? next.row : 0
  return {
    turn: RIGHT + (LEFT - RIGHT) * r,
    up: rowHeight(l.row) + (rowHeight(nextRow) - rowHeight(l.row)) * r
  }
}
