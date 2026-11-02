import { normalize, rotateAboutRadians, type Point } from "../geometry/math.js"

export interface ArmSample {
  readonly p: Point
  readonly w: number
  readonly root: boolean
}

export interface DrapeArm {
  readonly key: number
  readonly R: Point
  readonly pts: ReadonlyArray<ArmSample>
  readonly tipOut: number
}

export interface BundlePiece {
  readonly S: Point
  readonly T: Point
  readonly w: number
}

const NARROW_COS = Math.cos((35 * Math.PI) / 180)

export function linePts(S: Point, T: Point, k0 = 2): Array<Point> {
  const a: Array<Point> = []
  for (let k = k0; k <= 8; k++)
    a.push([S[0] + ((T[0] - S[0]) * k) / 8, S[1] + ((T[1] - S[1]) * k) / 8])
  return a
}

export function clearance(
  pts: ReadonlyArray<Point>,
  hw: number,
  obs: ReadonlyArray<ArmSample>
): number {
  let m = Infinity
  for (const q of pts)
    for (const o of obs) m = Math.min(m, Math.hypot(q[0] - o.p[0], q[1] - o.p[1]) - hw - o.w)
  return m
}

export function bundleClearance(
  pieces: ReadonlyArray<BundlePiece>,
  obs: ReadonlyArray<ArmSample>,
  a: number
): number {
  const C0 = pieces[0]!.S
  return Math.min(
    ...pieces.map(({ S, T, w }) =>
      clearance(
        linePts(S, T).map((q) => rotateAboutRadians(q, C0, a)),
        w,
        obs
      )
    )
  )
}

export function bundleSwing(
  pieces: ReadonlyArray<BundlePiece>,
  obs: ReadonlyArray<ArmSample>,
  sg: number,
  max: number
): number {
  if (!obs.length) return 0
  if (bundleClearance(pieces, obs, 0) >= 0) return 0
  let best = 0
  let bc = bundleClearance(pieces, obs, 0)
  for (const side of sg ? [sg] : [1, -1]) {
    for (let d = 2; d <= max; d += 2) {
      const a = (side * d * Math.PI) / 180
      const c = bundleClearance(pieces, obs, a)
      if (c >= 0) return a
      if (c > bc) {
        bc = c
        best = a
      }
    }
  }
  return best
}

export function meetsNarrowly(arm: DrapeArm, C0: Point, a: number, piece: BundlePiece): boolean {
  const pts = linePts(piece.S, piece.T, 0).map((q) => rotateAboutRadians(q, C0, a))
  const inArm = pts.map((q) => arm.pts.some((o) => Math.hypot(q[0] - o.p[0], q[1] - o.p[1]) < o.w))
  if (inArm.every(Boolean)) return false
  if (touchesRoot(arm, pts, piece.w)) return true
  if (!inArm.some(Boolean)) return false
  const k = inArm.findIndex((v, i) => i && v !== inArm[i - 1])
  const q = pts[k]!
  const prev = pts[k - 1]!
  const dq = normalize([q[0] - prev[0], q[1] - prev[1]])
  const da = spineDirectionNear(arm, q)
  return Math.abs(dq[0] * da[0] + dq[1] * da[1]) > NARROW_COS
}

function touchesRoot(arm: DrapeArm, pts: ReadonlyArray<Point>, w: number): boolean {
  return pts
    .slice(2)
    .some((q) => arm.pts.some((o) => o.root && Math.hypot(q[0] - o.p[0], q[1] - o.p[1]) < o.w + w))
}

function spineDirectionNear(arm: DrapeArm, q: Point): Point {
  let bi = 0
  let bd = Infinity
  arm.pts.forEach((o, i) => {
    const d = Math.hypot(q[0] - o.p[0], q[1] - o.p[1])
    if (d < bd) {
      bd = d
      bi = i
    }
  })
  const a0 = arm.pts[Math.max(0, bi - 1)]!.p
  const a1 = arm.pts[Math.min(arm.pts.length - 1, bi + 1)]!.p
  return normalize([a1[0] - a0[0], a1[1] - a0[1]])
}
