import ClipperLib from "clipper-lib"

import { pointText, type Point } from "../geometry/math.js"

export type ClipPath = ClipperLib.Path
export type ClipPaths = ClipperLib.Paths

export const SCALE = 100

const { Clipper, ClipperOffset, ClipType, EndType, JoinType, PolyFillType, PolyType, PolyTree } =
  ClipperLib

export const toClip = (pts: ReadonlyArray<Point>): ClipPath =>
  pts.map(([x, y]) => ({ X: Math.round(x * SCALE), Y: Math.round(y * SCALE) }))

export const fromClip = (pp: ClipPath): Array<Point> => pp.map((q) => [q.X / SCALE, q.Y / SCALE])

export const pathsD = (paths: ClipPaths): string =>
  paths.map((pp) => `M${fromClip(pp).map(pointText).join("L")}Z`).join("")

export function simplified(pts: ReadonlyArray<Point>): ClipPaths {
  let c = toClip(pts)
  if (!Clipper.Orientation(c)) c = c.toReversed()
  return Clipper.SimplifyPolygon(c, PolyFillType.pftNonZero)
}

export function oriented(pts: ReadonlyArray<Point>): ClipPaths {
  const c = toClip(pts)
  return [Clipper.Orientation(c) ? c : c.toReversed()]
}

export const rectangle = (x0: number, y0: number, x1: number, y1: number): ClipPath =>
  toClip([
    [x0, y0],
    [x1, y0],
    [x1, y1],
    [x0, y1]
  ])

export const circle = (q: Point, r: number): ClipPath =>
  toClip(
    Array.from({ length: 72 }, (_, k): Point => [
      q[0] + r * Math.cos((k * Math.PI) / 36),
      q[1] + r * Math.sin((k * Math.PI) / 36)
    ])
  )

export function offset(paths: ClipPaths, dd: number, miter = false): ClipPaths {
  const co = new ClipperOffset(2, 0.25 * SCALE)
  const r: ClipPaths = []
  const join = miter || Math.abs(dd) < 3 ? JoinType.jtMiter : JoinType.jtRound
  co.AddPaths(Clipper.CleanPolygons(paths, 0.03 * SCALE), join, EndType.etClosedPolygon)
  co.Execute(r, dd * SCALE)
  return r
}

const combine = (ct: ClipperLib.ClipType, a: ClipPaths, b: ClipPaths): ClipPaths => {
  const c = new Clipper()
  const r: ClipPaths = []
  c.AddPaths(a, PolyType.ptSubject, true)
  c.AddPaths(b, PolyType.ptClip, true)
  c.Execute(ct, r, PolyFillType.pftNonZero, PolyFillType.pftNonZero)
  return r
}

export const union = (a: ClipPaths, b: ClipPaths): ClipPaths => combine(ClipType.ctUnion, a, b)
export const intersection = (a: ClipPaths, b: ClipPaths): ClipPaths =>
  combine(ClipType.ctIntersection, a, b)
export const difference = (a: ClipPaths, b: ClipPaths): ClipPaths =>
  combine(ClipType.ctDifference, a, b)

export const area = (pp: ClipPath): number => Clipper.Area(pp)

export const isOuter = (pp: ClipPath): boolean => Clipper.Orientation(pp)

export function strictlyInside(q: Point, paths: ClipPaths): boolean {
  const pt = { X: Math.round(q[0] * SCALE), Y: Math.round(q[1] * SCALE) }
  return paths.some((pp) => Clipper.PointInPolygon(pt, pp) === 1)
}

export function clipOpenPath(
  pts: ReadonlyArray<Point>,
  keep: ClipPaths
): ReadonlyArray<ReadonlyArray<Point>> {
  const c = new Clipper()
  const tree = new PolyTree()
  c.AddPath(toClip(pts), PolyType.ptSubject, false)
  c.AddPaths(keep, PolyType.ptClip, true)
  c.Execute(ClipType.ctIntersection, tree, PolyFillType.pftNonZero, PolyFillType.pftNonZero)
  return Clipper.OpenPathsFromPolyTree(tree).map(fromClip)
}
