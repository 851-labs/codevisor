import type { Matrix } from "../arms/arm-pose.js"
import { RAD, type Point } from "../geometry/math.js"

export const IDENTITY: Matrix = [1, 0, 0, 1, 0, 0]

const TRANSFORM_OPS = /(translate|rotate|scale)\(([^)]*)\)/g

export const multiply = (m: Matrix, n: Matrix): Matrix => [
  m[0] * n[0] + m[2] * n[1],
  m[1] * n[0] + m[3] * n[1],
  m[0] * n[2] + m[2] * n[3],
  m[1] * n[2] + m[3] * n[3],
  m[0] * n[4] + m[2] * n[5] + m[4],
  m[1] * n[4] + m[3] * n[5] + m[5]
]

export const apply = (m: Matrix, [x, y]: Point): Point => [
  m[0] * x + m[2] * y + m[4],
  m[1] * x + m[3] * y + m[5]
]

export const invert = (m: Matrix): Matrix => {
  const d = m[0] * m[3] - m[1] * m[2]
  return [
    m[3] / d,
    -m[1] / d,
    -m[2] / d,
    m[0] / d,
    (m[2] * m[5] - m[3] * m[4]) / d,
    (m[1] * m[4] - m[0] * m[5]) / d
  ]
}

export const rotationAbout = (deg: number, [x, y]: Point): Matrix => {
  const r = deg * RAD
  const c = Math.cos(r)
  const s = Math.sin(r)
  return [c, s, -s, c, x - (c * x - s * y), y - (s * x + c * y)]
}

export const matrixText = (m: Matrix): string => m.map((v) => v.toFixed(4)).join(" ")

export function parseTransform(str: string): Matrix {
  let m = IDENTITY
  for (const [, op, args = ""] of str.matchAll(TRANSFORM_OPS)) {
    const a = args
      .trim()
      .split(/[\s,]+/)
      .map(Number)
    if (op === "translate") m = multiply(m, [1, 0, 0, 1, a[0]!, a[1] || 0])
    else if (op === "scale") m = multiply(m, [a[0]!, 0, 0, a[1] ?? a[0]!, 0, 0])
    else m = multiply(m, rotationAbout(a[0]!, [a[1] || 0, a[2] || 0]))
  }
  return m
}

export interface PlacedProp {
  readonly x: number
  readonly y: number
  readonly rot: number
  readonly k: number
}

export const placement = (q: PlacedProp): Matrix => [
  Math.cos(q.rot * RAD) * q.k,
  Math.sin(q.rot * RAD) * q.k,
  -Math.sin(q.rot * RAD) * q.k,
  Math.cos(q.rot * RAD) * q.k,
  q.x,
  q.y
]
