import { mix, namedColors, type NamedColor } from "../color/colors.js"
import type { BotMascotColor } from "../color/palette.js"
import { cubicPoint, f2, s01, type Point } from "../geometry/math.js"

export const HANDLE: readonly [Point, Point, Point, Point] = [
  [-17, -38],
  [27, -41],
  [27, 41],
  [-17, 38]
]

const SAMPLES = 64
const FACE_DOTS: ReadonlyArray<Point> = [
  [0, -5],
  [0, 0],
  [0, 5],
  [-1.4, -2.5],
  [-1.4, 2.5]
]

const phoneColor: Readonly<Record<BotMascotColor, NamedColor>> = {
  sunny: "blue",
  mint: "purple",
  lilac: "yellow",
  bubblegum: "green",
  sky: "red",
  tomato: "blue",
  electric: "yellow",
  dream: "green",
  ruby: "teal",
  tangerine: "blue",
  lime: "purple",
  clover: "red",
  aqua: "red",
  grape: "green",
  orchid: "teal",
  cocoa: "blue",
  slate: "yellow",
  classic: "blue"
}

const handsets = new Map<string, string>()

export const handsetColor = (key: BotMascotColor): string =>
  namedColors[phoneColor[key]] || namedColors.blue

export const handlePoint = (t: number): Point =>
  cubicPoint(HANDLE[0], HANDLE[1], HANDLE[2], HANDLE[3], t)

export function handset(O: string, C: string): string {
  const key = O + C
  const cached = handsets.get(key)
  if (cached !== undefined) return cached
  const drawn = drawHandset(O, C)
  handsets.set(key, drawn)
  return drawn
}

function handleTangent(t: number): Point {
  const [P0, P1, P2, P3] = HANDLE
  const d = [0, 1].map(
    (k) =>
      3 * (1 - t) ** 2 * (P1[k]! - P0[k]!) +
      6 * t * (1 - t) * (P2[k]! - P1[k]!) +
      3 * t * t * (P3[k]! - P2[k]!)
  )
  const m = Math.hypot(d[0]!, d[1]!)
  return [d[0]! / m, d[1]! / m]
}

function halfWidth(t: number): number {
  const u = Math.min(t, 1 - t)
  return 5.8 + 5.4 * (1 - s01((u - 0.08) / 0.13)) + 2.2 * (1 - s01(u / 0.06))
}

function depth(t: number): number {
  const u = Math.min(t, 1 - t)
  return 3.8 * s01((u - 0.16) / 0.1)
}

const polyline = (pts: ReadonlyArray<Point>): string =>
  pts.map(([x, y], i) => `${i ? "L" : "M"}${f2(x)} ${f2(y)}`).join("")

const segment = (pts: ReadonlyArray<Point>, a: number, b: number): string =>
  polyline(pts.slice(Math.round(a * SAMPLES), Math.round(b * SAMPLES) + 1))

function drawHandset(O: string, C: string): string {
  const light = mix(C, "#ffffff", 0.3)
  const dark = mix(C, "#000000", 0.28)
  const { outer, inner, deep, normals } = handleEdges()
  const inset = (k: number): ReadonlyArray<Point> =>
    outer.map(([x, y], i): Point => [x - normals[i]![0] * k, y - normals[i]![1] * k])
  const sil = polyline([...outer, ...deep.toReversed()]) + "Z"
  const front = polyline([...outer, ...inner.toReversed()]) + "Z"
  const side = polyline([...inner, ...deep.toReversed()]) + "Z"
  const p = handlePoint(0.27)
  const d = handleTangent(0.27)
  return (
    `<path d="${sil}" fill="none" stroke="${O}" stroke-width="10" stroke-linejoin="round"/>` +
    `<path d="${front}" fill="${C}"/><path d="${side}" fill="${dark}"/>` +
    `<path d="${segment(inner, 0.16, 0.84)}" fill="none" stroke="${O}" stroke-width="2.2" stroke-opacity=".7" stroke-linecap="round"/>` +
    `<path d="${segment(inset(3), 0.1, 0.9)}" fill="none" stroke="${light}" stroke-width="2.6" stroke-linecap="round"/>` +
    `<path d="${segment(inset(4.5), 0.36, 0.56)}" fill="none" stroke="#fff" stroke-opacity=".92" stroke-width="2.8" stroke-linecap="round"/>` +
    cupFace(O, light, dark, 0) +
    cupFace(O, light, dark, 1) +
    `<circle cx="${f2(p[0] + d[1] * 1.5)}" cy="${f2(p[1] - d[0] * 1.5)}" r="1.8" fill="#fff" fill-opacity=".92"/>`
  )
}

interface HandleEdges {
  readonly outer: ReadonlyArray<Point>
  readonly inner: ReadonlyArray<Point>
  readonly deep: ReadonlyArray<Point>
  readonly normals: ReadonlyArray<Point>
}

function handleEdges(): HandleEdges {
  const outer: Array<Point> = []
  const inner: Array<Point> = []
  const deep: Array<Point> = []
  const normals: Array<Point> = []
  for (let i = 0; i <= SAMPLES; i++) {
    const t = i / SAMPLES
    const p = handlePoint(t)
    const d = handleTangent(t)
    const n: Point = [d[1], -d[0]]
    const h = halfWidth(t)
    normals.push(n)
    outer.push([p[0] + n[0] * h, p[1] + n[1] * h])
    inner.push([p[0] - n[0] * h, p[1] - n[1] * h])
    deep.push([p[0] - n[0] * (h + depth(t)), p[1] - n[1] * (h + depth(t))])
  }
  return { outer, inner, deep, normals }
}

function cupFace(O: string, light: string, dark: string, t: number): string {
  const [x, y] = handlePoint(t)
  const h = halfWidth(t)
  const dots = FACE_DOTS.map(
    ([dx, dy]) => `<circle cx="${f2(x + dx)}" cy="${f2(y + dy)}" r="1.25" fill="${O}"/>`
  ).join("")
  return (
    `<ellipse cx="${f2(x)}" cy="${f2(y)}" rx="5.5" ry="${f2(h)}" fill="${light}" stroke="${O}" stroke-width="4.5"/>` +
    `<ellipse cx="${f2(x)}" cy="${f2(y)}" rx="3.6" ry="${f2(h - 3)}" fill="none" stroke="${O}" stroke-width="2"/>` +
    `<ellipse cx="${f2(x)}" cy="${f2(y)}" rx="2.4" ry="${f2(h - 5)}" fill="${dark}"/>` +
    dots
  )
}
