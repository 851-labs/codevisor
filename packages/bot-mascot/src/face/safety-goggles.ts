import { glint } from "../render/shine.js"
import {
  acrossOf,
  downOf,
  goggleShape,
  goggleY,
  outlined,
  oval,
  sideBands,
  type Axis,
  type Lens
} from "./eyewear-lens.js"

const ELASTIC = "#26272E"
const CLEAR_PLASTIC = "#DCEBF5"
const PLASTIC_EDGE = "#9FB3C4"
const HOLE = "#6F8496"
const FRAME_WHITE = ".8"
const VENT_TOP = [-44, -33, -22, 22, 33, 44] as const
const VENT_SIDE = [-22, -12, -2, 8] as const

interface Face {
  readonly lens: Lens
  readonly X: Axis
  readonly Y: Axis
}

export function safety(lens: Lens): string {
  const face = faceOf(lens)
  const frame = goggleShape(face.X, face.Y, 62, 45, 10)
  const window = goggleShape(face.X, face.Y, 51, 34, 9)
  return elastic(face) + shell(frame, window) + ventHoles(face) + glare(face, frame)
}

function faceOf(lens: Lens): Face {
  return { lens, X: acrossOf(lens), Y: downOf(goggleY(lens)) }
}

function elastic({ lens, Y }: Face): string {
  return sideBands(lens, Y, 58, 4.5, `fill="${ELASTIC}" ${outlined(lens, 5)} paint-order="stroke"`)
}

function shell(frame: string, window: string): string {
  return (
    `<path d="${frame}" fill="${CLEAR_PLASTIC}" fill-opacity=".22" stroke="${PLASTIC_EDGE}" stroke-opacity=".55" stroke-width="10" stroke-linejoin="round"/>` +
    `<path d="${frame}${window}" fill="#fff" fill-opacity="${FRAME_WHITE}" fill-rule="evenodd"/>` +
    `<path d="${frame}" fill="none" stroke="#fff" stroke-opacity=".92" stroke-width="5.5" stroke-linejoin="round"/>` +
    `<path d="${window}" fill="none" stroke="${PLASTIC_EDGE}" stroke-opacity=".45" stroke-width="2.5" stroke-linejoin="round"/>`
  )
}

function glare({ lens, X, Y }: Face, clip: string): string {
  return (
    `<clipPath id="${lens.id}c"><path d="${clip}"/></clipPath>` +
    `<g class="glare" clip-path="url(#${lens.id}c)">` +
    glint(`M${X(14)} ${Y(-22)}Q${X(36)} ${Y(-23)} ${X(41)} ${Y(-8)}`, 4.5) +
    `<path d="M${X(-42)} ${Y(16)}L${X(-24)} ${Y(-24)}" fill="none" stroke="#fff" stroke-opacity=".6" stroke-width="3" stroke-linecap="round"/></g>`
  )
}

function hole({ lens, X, Y }: Face, u: number, v: number): string {
  return oval(Number(X(u)), Number(Y(v)), 2.5 * lens.k, 2.5, `fill="${HOLE}" fill-opacity=".55"`)
}

function ventHoles(face: Face): string {
  const top = VENT_TOP.map((u) => hole(face, u, -39.5)).join("")
  const sides = VENT_SIDE.map((v) => hole(face, -56.5, v) + hole(face, 56.5, v)).join("")
  return top + sides
}
