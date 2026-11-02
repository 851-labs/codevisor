import { flipAngle, FLIP_DOWN, FLIP_UP } from "../effects/clipboard-reading.js"
import { lerp2, RAD, smootherstep, type Point } from "../geometry/math.js"

export type CarryLayer = "front" | "behind" | "between"

export interface FlipState {
  readonly f: number
  readonly target?: Point
  readonly layer?: CarryLayer
}

export const PAGE_HINGE_Y = 309
export const PAGE_LENGTH = 68
export const PAGE_GRIP_X = 284

const HOLD_BOARD: Point = [284, 351]
const OUT: Point = [300, 350]

export const holdPoint = (side: number): Point => [
  side > 0 ? HOLD_BOARD[0] : 500 - HOLD_BOARD[0],
  HOLD_BOARD[1]
]

export function pageGrip(th: number): Point {
  return [
    PAGE_GRIP_X,
    PAGE_HINGE_Y + gripFraction(th) * PAGE_LENGTH * Math.cos(th * RAD) + 6 * edgeOn(th)
  ]
}

export function flipState(tt: number): FlipState {
  const e = (a: number, b: number): number => smootherstep((tt - a) / (b - a))
  const H = HOLD_BOARD
  if (tt < 3.3 || tt > 8.75 || (tt > 5.3 && tt < 6.7)) return { f: 0 }
  if (tt < 5.3) return flipOver(tt, e, H)
  return flipBack(tt, e, H)
}

type Ease = (a: number, b: number) => number

function flipOver(tt: number, e: Ease, H: Point): FlipState {
  if (tt < 3.6) return { f: e(3.3, 3.6), target: lerp2(H, OUT, e(3.3, 3.6)), layer: "front" }
  if (tt < FLIP_UP[0])
    return { f: 1, target: lerp2(OUT, pageGrip(0), e(3.6, 3.95)), layer: "behind" }
  if (tt < FLIP_UP[0] + FLIP_UP[1]) return carried(flipAngle(tt))
  if (tt < 4.95) return { f: 1, target: lerp2(pageGrip(360), OUT, e(4.7, 4.95)), layer: "between" }
  const u = e(4.95, 5.3)
  return { f: 1 - u, target: lerp2(OUT, H, u), layer: "front" }
}

function flipBack(tt: number, e: Ease, H: Point): FlipState {
  if (tt < 7.0) return { f: e(6.7, 7.0), target: lerp2(H, OUT, e(6.7, 7.0)), layer: "front" }
  if (tt < FLIP_DOWN[0])
    return { f: 1, target: lerp2(OUT, pageGrip(360), e(7.0, 7.35)), layer: "between" }
  if (tt < FLIP_DOWN[0] + FLIP_DOWN[1]) return carried(flipAngle(tt))
  if (tt < 8.4) return { f: 1, target: lerp2(pageGrip(0), OUT, e(8.1, 8.4)), layer: "behind" }
  const u = e(8.4, 8.75)
  return { f: 1 - u, target: lerp2(OUT, H, u), layer: "front" }
}

function carried(th: number): FlipState {
  return { f: 1, target: pageGrip(th), layer: th < 270 ? "behind" : "between" }
}

function gripFraction(th: number): number {
  if (th <= 90) return 1
  return th < 270 ? 0.15 : 0.46
}

function edgeOn(th: number): number {
  return Math.exp(-((Math.min(Math.abs(th - 90), Math.abs(th - 270)) / 32) ** 2))
}
