import type { Body } from "../body/zones.js"
import { CREAM, mix, type WearTint } from "../color/colors.js"
import type { Palette } from "../color/palette.js"
import { f2, s01, type Point } from "../geometry/math.js"
import {
  ARM_HALF,
  band,
  button,
  curve,
  edge,
  level,
  poly,
  seam,
  shoes,
  shouldered,
  stitch,
  type GarmentKit
} from "./garment-kit.js"

export type GarmentDrawing = (
  P: Palette,
  C: WearTint,
  kit: GarmentKit,
  A: string,
  body: Body
) => readonly [string, string]

const SHIRT = "#F7F5F0"

export function dress(
  P: Palette,
  _C: WearTint,
  kit: GarmentKit,
  A: string,
  body: Body
): readonly [string, string] {
  const { d, pt } = kit
  const top = shouldered(body, (x) => 320 + 3 * Math.exp(-(((x - 250) / 50) ** 2)))
  const bodice = d(`dress-bodice@${body.shoulderY.toFixed(1)}`, band(top, level(348)))
  const collars = [-1, 1].map((sg) => d(`dress-collar${sg}`, () => collarPoints(sg), true))
  const buttons = [331, 340]
    .map((y) => {
      const [x, yy] = pt(250, y)
      return `<circle cx="${f2(x)}" cy="${f2(yy)}" r="2.8" fill="${CREAM}" stroke="${P.outline}" stroke-width="2.2"/>`
    })
    .join("")
  const collarSvg = collars.map((c) => `<path d="${c}" fill="${CREAM}"/>` + edge(P, c, 4)).join("")
  return [`<path d="${bodice}" fill="${A}"/>` + edge(P, bodice) + collarSvg + buttons, bodice]
}

export function suit(
  P: Palette,
  _C: WearTint,
  kit: GarmentKit,
  A: string,
  body: Body
): readonly [string, string] {
  const { d } = kit
  const lap = mix(A, "#000000", 0.18)
  const trousers = d("suit-trousers", band(level(346), level(399)))
  const [sh, shD] = shoes(P, kit, "#2A2420")
  const jacket = d(
    `suit-jacket@${body.shoulderY.toFixed(1)}`,
    band(shouldered(body, level(318)), level(372))
  )
  const vee = d(
    "suit-vee",
    poly(
      [
        [224, 316],
        [276, 316],
        [250, 347]
      ],
      true
    )
  )
  const lapels = [-1, 1].map((sg) => d(`suit-lapel${sg}`, poly(lapelPoints(sg), true)))
  const bow = d("suit-bow", poly(BOW, true))
  const knot = d("suit-knot", poly(KNOT, true))
  const pocket = d("suit-square", poly(POCKET, true))
  const flaps = [
    d("suit-flap0", curve(level(360), 172, 200), false),
    d("suit-flap1", curve(level(360), 300, 328), false)
  ]
  const creases =
    seam(
      P,
      d(
        "suit-crease0",
        poly([
          [190, 376],
          [190, 396]
        ]),
        false
      ),
      3,
      0.35
    ) +
    seam(
      P,
      d(
        "suit-crease1",
        poly([
          [310, 376],
          [310, 396]
        ]),
        false
      ),
      3,
      0.35
    )
  return [
    `<path d="${trousers}" fill="${A}"/>` +
      creases +
      edge(P, trousers) +
      sh +
      `<path d="${jacket}" fill="${A}"/>` +
      flaps.map((f) => seam(P, f, 3.5, 0.5)).join("") +
      edge(P, jacket) +
      `<path d="${vee}" fill="${SHIRT}"/>` +
      lapels.map((l) => `<path d="${l}" fill="${lap}"/>` + edge(P, l, 4.5)).join("") +
      `<path d="${pocket}" fill="${SHIRT}"/>` +
      edge(P, pocket, 3) +
      `<path d="${bow}" fill="#D8434B"/>` +
      edge(P, bow, 4) +
      `<path d="${knot}" fill="#B3323A"/>` +
      edge(P, knot, 3),
    `${trousers}${jacket}${shD}`
  ]
}

export function overalls(
  P: Palette,
  C: WearTint,
  kit: GarmentKit,
  _A: string,
  body: Body
): readonly [string, string] {
  const layout = overallsLayout(kit, body)
  const d = (key: string, make: () => ReadonlyArray<Point>, closed?: boolean): string =>
    kit.d(kit.zoned ? `${key}@${kit.S.toFixed(1)}@${body.shoulderY.toFixed(1)}` : key, make, closed)
  const den = mix(C.denim, "#ffffff", 0.12)
  const bodyD = d("overalls", band(layout.bib, level(400)))
  const cuff = d("cuffs", band(level(389), level(400)))
  const strapD = [-1, 1].map((sg) =>
    d(
      `strap${sg}`,
      poly(
        layout.strap.map(([x, y]): Point => [250 + sg * (250 - x), y]),
        true
      )
    )
  )
  const straps = strapD.map((sd) => `<path d="${sd}" fill="${den}"/>` + edge(P, sd, 5)).join("")
  const pocket = d("bib-pocket", poly(layout.pocket, true))
  const buttons =
    button(P, kit.pt(213, layout.buttonY)) +
    button(P, kit.pt(287, layout.buttonY)) +
    button(P, kit.pt(170, layout.sideButtonY), 3.5) +
    button(P, kit.pt(330, layout.sideButtonY), 3.5)
  return [
    straps +
      `<path d="${bodyD}" fill="${den}"/>` +
      `<path d="${pocket}" fill="${mix(den, "#ffffff", 0.12)}"/>` +
      seam(P, pocket, 3.5, 0.55) +
      seam(P, d("waist-seam", curve(level(layout.seamY), 150, 350), false)) +
      stitch(d("stitch-c", curve(level(385)), false)) +
      buttons +
      `<path d="${cuff}" fill="${mix(den, "#ffffff", 0.2)}"/>` +
      edge(P, cuff, 5) +
      edge(P, bodyD),
    `${bodyD}${strapD.join("")}`
  ]
}

interface OverallsLayout {
  readonly bib: (x: number) => number
  readonly seamY: number
  readonly strap: ReadonlyArray<Point>
  readonly pocket: ReadonlyArray<Point>
  readonly buttonY: number
  readonly sideButtonY: number
}

const STRAP_CLEAR = 12

function overallsLayout(kit: GarmentKit, body: Body): OverallsLayout {
  const { zoned, zy, S } = kit
  const Y = (dyF: number): number => zy(S + dyF)
  const seamF = Math.max(346, S + 31)
  const seamY = zoned ? zy(seamF) : 346
  const bibTop = zoned ? Y(-6) : 322
  const bibAt = (x: number): number => bibTop + 3 * (1 - Math.min(1, ((x - 250) / 47) ** 2))
  const At = body.shoulderY - ARM_HALF
  const pk = zoned ? [Y(6), Y(18)] : [330, 342]
  return {
    bib: (x) => seamY - (seamY - bibAt(x)) * s01((44 - Math.abs(x - 250)) / 5),
    seamY,
    strap: zoned ? zonedStrap(Y, zy, At) : ORIGINAL_STRAP,
    pocket: [
      [236, pk[0]!],
      [264, pk[0]!],
      [264, pk[1]!],
      [236, pk[1]!]
    ],
    buttonY: zoned ? Y(0) : 328,
    sideButtonY: zoned ? zy(seamF + 6) : 352
  }
}

function zonedStrap(
  Y: (dy: number) => number,
  zy: (y: number) => number,
  At: number
): ReadonlyArray<Point> {
  return [
    [207, Y(1)],
    [220, Y(-6)],
    [162, zy(At - STRAP_CLEAR - 13)],
    [150, zy(At - STRAP_CLEAR)]
  ]
}

const ORIGINAL_STRAP: ReadonlyArray<Point> = [
  [207, 327],
  [220, 322],
  [156, 298],
  [150, 308]
]

const BOW: ReadonlyArray<Point> = [
  [250, 322],
  [237, 315],
  [235, 324],
  [237, 331],
  [250, 324],
  [263, 331],
  [265, 324],
  [263, 315]
]

const KNOT: ReadonlyArray<Point> = [
  [247, 319],
  [253, 319],
  [253, 327],
  [247, 327]
]

const POCKET: ReadonlyArray<Point> = [
  [284, 331],
  [298, 330],
  [294, 324],
  [290, 327],
  [286, 323]
]

function lapelPoints(sg: number): ReadonlyArray<Point> {
  const X = (x: number): number => 250 + sg * (x - 250)
  return [
    [X(224), 316],
    [X(212), 318],
    [X(222), 331],
    [X(246), 345],
    [X(250), 347]
  ]
}

function collarPoints(sg: number): ReadonlyArray<Point> {
  const a: Array<Point> = []
  for (let i = 0; i <= 12; i++) {
    const t = (Math.PI * i) / 12
    a.push([250 + sg * (1 + 12 - 12 * Math.cos(t)), 322 + 10 * Math.sin(t)])
  }
  return a
}
