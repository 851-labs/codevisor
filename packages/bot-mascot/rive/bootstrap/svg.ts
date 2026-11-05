export type Matrix = [number, number, number, number, number, number]
export interface El {
  tag: string
  attrs: Record<string, string>
  children: El[]
}

export const IDENTITY: Matrix = [1, 0, 0, 1, 0, 0]

export function parseSvg(text: string): El {
  const root: El = { tag: "#root", attrs: {}, children: [] }
  const stack = [root]
  const re = /<(\/?)([a-zA-Z]+)((?:\s+[\w:-]+="[^"]*")*)\s*(\/?)>/g
  let m: RegExpExecArray | null
  while ((m = re.exec(text))) {
    const [, close, tag, attrText, selfClose] = m
    if (close) {
      stack.pop()
      continue
    }
    const attrs: Record<string, string> = {}
    for (const a of attrText.matchAll(/([\w:-]+)="([^"]*)"/g)) attrs[a[1]] = a[2]!
    const el: El = { tag: tag, attrs, children: [] }
    stack[stack.length - 1].children.push(el)
    if (!selfClose) stack.push(el)
  }
  return root
}

export const multiply = (a: Matrix, b: Matrix): Matrix => [
  a[0] * b[0] + a[2] * b[1],
  a[1] * b[0] + a[3] * b[1],
  a[0] * b[2] + a[2] * b[3],
  a[1] * b[2] + a[3] * b[3],
  a[0] * b[4] + a[2] * b[5] + a[4],
  a[1] * b[4] + a[3] * b[5] + a[5]
]

export const apply = (m: Matrix, [x, y]: readonly [number, number]): [number, number] => [
  m[0] * x + m[2] * y + m[4],
  m[1] * x + m[3] * y + m[5]
]

export function parseTransform(text: string | undefined): Matrix {
  let m = IDENTITY
  if (!text) return m
  for (const t of text.matchAll(/(\w+)\(([^)]*)\)/g)) {
    const v = t[2]
      .split(/[\s,]+/)
      .filter(Boolean)
      .map(Number)
    m = multiply(m, one(t[1], v))
  }
  return m
}

function one(kind: string, v: number[]): Matrix {
  if (kind === "translate") return [1, 0, 0, 1, v[0], v[1] ?? 0]
  if (kind === "scale") return [v[0], 0, 0, v[1] ?? v[0], 0, 0]
  if (kind === "matrix") return [v[0], v[1], v[2], v[3], v[4], v[5]]
  if (kind === "rotate") {
    const a = (v[0] * Math.PI) / 180
    const r: Matrix = [Math.cos(a), Math.sin(a), -Math.sin(a), Math.cos(a), 0, 0]
    if (v.length < 3) return r
    return multiply(multiply([1, 0, 0, 1, v[1], v[2]], r), [1, 0, 0, 1, -v[1], -v[2]])
  }
  throw new Error(`transform ${kind}`)
}

export interface Vertex {
  p: [number, number]
  inH?: [number, number]
  outH?: [number, number]
}
export interface Contour {
  vertices: Vertex[]
  closed: boolean
}

export function pathContours(d: string): Contour[] {
  const toks = d.match(/[a-zA-Z]|-?\d*\.?\d+(?:e-?\d+)?/g) ?? []
  const out: Contour[] = []
  let cur: Contour | null = null
  let pos: [number, number] = [0, 0]
  let start: [number, number] = [0, 0]
  let cmd = ""
  let i = 0
  const num = () => Number(toks[i++])
  const last = () => cur!.vertices[cur!.vertices.length - 1]
  const add = (p: [number, number], inH?: [number, number]) => {
    cur!.vertices.push({ p, ...(inH ? { inH } : {}) })
    pos = p
  }
  while (i < toks.length) {
    if (/[a-zA-Z]/.test(toks[i])) cmd = toks[i++]!
    const rel = cmd === cmd.toLowerCase()
    const at = (x: number, y: number): [number, number] => (rel ? [pos[0] + x, pos[1] + y] : [x, y])
    switch (cmd.toUpperCase()) {
      case "M": {
        cur = { vertices: [], closed: false }
        out.push(cur)
        const p = at(num(), num())
        start = p
        add(p)
        cmd = rel ? "l" : "L"
        break
      }
      case "L":
        add(at(num(), num()))
        break
      case "H": {
        const x = num()
        add([rel ? pos[0] + x : x, pos[1]])
        break
      }
      case "V": {
        const y = num()
        add([pos[0], rel ? pos[1] + y : y])
        break
      }
      case "C": {
        const c1 = at(num(), num())
        const c2 = at(num(), num())
        const p = at(num(), num())
        last().outH = c1
        add(p, c2)
        break
      }
      case "Q": {
        const q = at(num(), num())
        const p = at(num(), num())
        const p0 = pos
        last().outH = [p0[0] + (2 / 3) * (q[0] - p0[0]), p0[1] + (2 / 3) * (q[1] - p0[1])]
        add(p, [p[0] + (2 / 3) * (q[0] - p[0]), p[1] + (2 / 3) * (q[1] - p[1])])
        break
      }
      case "Z": {
        cur!.closed = true
        const vs = cur!.vertices
        const end = vs[vs.length - 1]
        if (vs.length > 1 && Math.hypot(end.p[0] - vs[0].p[0], end.p[1] - vs[0].p[1]) < 1e-3) {
          if (end.inH) vs[0].inH = end.inH
          vs.pop()
        }
        pos = start
        break
      }
      default:
        throw new Error(`path command ${cmd}`)
    }
  }
  return out
}

const K = 0.5522847498

export function ellipseContour(cx: number, cy: number, rx: number, ry: number): Contour {
  const pts: Array<[number, number, number, number]> = [
    [cx + rx, cy, 0, 1],
    [cx, cy + ry, -1, 0],
    [cx - rx, cy, 0, -1],
    [cx, cy - ry, 1, 0]
  ]
  return {
    closed: true,
    vertices: pts.map(([x, y, tx, ty]) => ({
      p: [x, y],
      inH: [x - tx * K * rx, y - ty * K * ry],
      outH: [x + tx * K * rx, y + ty * K * ry]
    }))
  }
}

export function rectContour(x: number, y: number, w: number, h: number, radius = 0): Contour {
  const r = Math.min(radius, w / 2, h / 2)
  if (!(r > 0)) {
    return {
      closed: true,
      vertices: [{ p: [x, y] }, { p: [x + w, y] }, { p: [x + w, y + h] }, { p: [x, y + h] }]
    }
  }
  const k = r * (1 - 0.5522847498)
  const [l, t, rt, b] = [x, y, x + w, y + h]
  return {
    closed: true,
    vertices: [
      corner([l + r, t], [l + k, t], [l + r, t]),
      corner([rt - r, t], [rt - r, t], [rt - k, t]),
      corner([rt, t + r], [rt, t + k], [rt, t + r]),
      corner([rt, b - r], [rt, b - r], [rt, b - k]),
      corner([rt - r, b], [rt - k, b], [rt - r, b]),
      corner([l + r, b], [l + r, b], [l + k, b]),
      corner([l, b - r], [l, b - k], [l, b - r]),
      corner([l, t + r], [l, t + r], [l, t + k])
    ]
  }
}

type Pt2 = [number, number]

const corner = (p: Pt2, inH: Pt2, outH: Pt2): Vertex => ({ p, inH, outH })

export const transformContour = (m: Matrix, c: Contour): Contour => ({
  closed: c.closed,
  vertices: c.vertices.map((v) => ({
    p: apply(m, v.p),
    ...(v.inH ? { inH: apply(m, v.inH) } : {}),
    ...(v.outH ? { outH: apply(m, v.outH) } : {})
  }))
})
