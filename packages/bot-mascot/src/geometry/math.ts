export type Point = readonly [number, number]

export const TAU = Math.PI * 2
export const RAD = Math.PI / 180

export const clamp = (v: number, a: number, b: number): number => Math.max(a, Math.min(b, v))

export const s01 = (x: number): number => {
  const c = clamp(x, 0, 1)
  return c * c * (3 - 2 * c)
}

export const smootherstep = (x: number): number => {
  const c = Math.max(0, Math.min(1, x))
  return c * c * c * (c * (6 * c - 15) + 10)
}

export const bump = (u: number): number => (u > 0 && u < 1 ? Math.sin(Math.PI * u) : 0)

export const f2 = (v: number): string => v.toFixed(2)

export const fa = (v: number): string => (Math.abs(v) < 5e-5 ? "0" : v.toFixed(4))

export const lerp = (a: number, b: number, u: number): number => a + (b - a) * u

export const lerp2 = (a: Point, b: Point, u: number): [number, number] => [
  lerp(a[0], b[0], u),
  lerp(a[1], b[1], u)
]

export const pointText = (p: Point): string => `${f2(p[0])} ${f2(p[1])}`

export const normalize = ([x, y]: Point): [number, number] => {
  const m = Math.hypot(x, y) || 1
  return [x / m, y / m]
}

export const subtract = (a: Point, b: Point): [number, number] => [a[0] - b[0], a[1] - b[1]]

export const distance = (a: Point, b: Point): number => Math.hypot(a[0] - b[0], a[1] - b[1])

export const rotateAbout = (p: Point, c: Point, deg: number): [number, number] => {
  const a = (deg * Math.PI) / 180
  const co = Math.cos(a)
  const si = Math.sin(a)
  const x = p[0] - c[0]
  const y = p[1] - c[1]
  return [c[0] + x * co - y * si, c[1] + x * si + y * co]
}

export const rotateAboutRadians = ([x, y]: Point, [cx, cy]: Point, a: number): [number, number] => {
  const c = Math.cos(a)
  const s = Math.sin(a)
  return [cx + (x - cx) * c - (y - cy) * s, cy + (x - cx) * s + (y - cy) * c]
}

export const wrapDegrees = (deg: number): number => {
  let v = deg
  while (v > 180) v -= 360
  while (v <= -180) v += 360
  return v
}

export const wrapRadians = (a: number): number => {
  let v = a
  while (v > Math.PI) v -= 2 * Math.PI
  while (v <= -Math.PI) v += 2 * Math.PI
  return v
}

export const at = <T>(list: ReadonlyArray<T>, index: number): T => list[index]!

export const last = <T>(list: ReadonlyArray<T>): T => list[list.length - 1]!

export const catmull = (pts: ReadonlyArray<Point>): string => {
  const n = pts.length
  let d = `M${f2(at(pts, 0)[0])} ${f2(at(pts, 0)[1])}`
  for (let i = 0; i < n; i++) {
    const p0 = at(pts, (i - 1 + n) % n)
    const p1 = at(pts, i)
    const p2 = at(pts, (i + 1) % n)
    const p3 = at(pts, (i + 2) % n)
    d +=
      `C${f2(p1[0] + (p2[0] - p0[0]) / 6)} ${f2(p1[1] + (p2[1] - p0[1]) / 6)} ` +
      `${f2(p2[0] - (p3[0] - p1[0]) / 6)} ${f2(p2[1] - (p3[1] - p1[1]) / 6)} ${f2(p2[0])} ${f2(p2[1])}`
  }
  return d + "Z"
}

export const taubin = (pts: ReadonlyArray<Point>, iterations: number): ReadonlyArray<Point> => {
  let p = pts
  const n = p.length
  for (let it = 0; it < iterations; it++) {
    for (const f of [0.5, -0.53]) {
      const prev = p
      p = prev.map((q, i) => {
        const a = at(prev, (i - 1 + n) % n)
        const b = at(prev, (i + 1) % n)
        return [
          q[0] + f * ((a[0] + b[0]) / 2 - q[0]),
          q[1] + f * ((a[1] + b[1]) / 2 - q[1])
        ] as const
      })
    }
  }
  return p
}

export const polylineD = (pts: ReadonlyArray<Point>): string =>
  "M" + pts.map(([x, y]) => `${f2(x)} ${f2(y)}`).join("L") + "Z"

export const quadraticPoint = (a: Point, c: Point, b: Point, u: number): [number, number] => [
  (1 - u) ** 2 * a[0] + 2 * u * (1 - u) * c[0] + u * u * b[0],
  (1 - u) ** 2 * a[1] + 2 * u * (1 - u) * c[1] + u * u * b[1]
]

export const cubicPoint = (a: Point, b: Point, c: Point, d: Point, u: number): [number, number] => {
  const v = 1 - u
  return [
    v ** 3 * a[0] + 3 * u * v ** 2 * b[0] + 3 * u * u * v * c[0] + u ** 3 * d[0],
    v ** 3 * a[1] + 3 * u * v ** 2 * b[1] + 3 * u * u * v * c[1] + u ** 3 * d[1]
  ]
}
