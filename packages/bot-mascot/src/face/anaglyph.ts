import { glint } from "../render/shine.js"
import {
  acrossOf,
  downOf,
  raisedBy,
  roundedBox,
  sideBands,
  type Axis,
  type Box,
  type Lens
} from "./eyewear-lens.js"

const CARD = "#FBFAF6"
const RED = "#E5484D"
const CYAN = "#22C3E6"
const TINT = ".72"
const LEFT_LENS: Box = { l: -61, t: -26, r: -8, b: 20 }
const RIGHT_LENS: Box = { l: 8, t: -26, r: 61, b: 20 }

export function anaglyph(lens: Lens): string {
  const X = acrossOf(lens)
  const Y = downOf(lens.y)
  return (
    stems(lens, Y) +
    twoLenses(X, Y) +
    `<path d="${notchedFrame(X, Y)}${lensWindows(X, Y)}" fill="${CARD}" fill-rule="evenodd"/>`
  )
}

function stems(lens: Lens, Y: Axis): string {
  return sideBands(lens, raisedBy(Y, -10), 62, 19, `fill="${CARD}"`)
}

function lensWindows(X: Axis, Y: Axis): string {
  return roundedBox(X, Y, LEFT_LENS, 9) + roundedBox(X, Y, RIGHT_LENS, 9)
}

function twoLenses(X: Axis, Y: Axis): string {
  return (
    `<path d="${roundedBox(X, Y, LEFT_LENS, 9)}" fill="${CYAN}" fill-opacity="${TINT}"/>` +
    `<path d="${roundedBox(X, Y, RIGHT_LENS, 9)}" fill="${RED}" fill-opacity="${TINT}"/>` +
    `<g class="glare">${glint(`M${X(30)} ${Y(-17)}Q${X(46)} ${Y(-18)} ${X(50)} ${Y(-6)}`, 4.5)}</g>`
  )
}

function notchedFrame(X: Axis, Y: Axis): string {
  return (
    `M${X(-60)} ${Y(-36)}L${X(60)} ${Y(-36)}Q${X(70)} ${Y(-36)} ${X(70)} ${Y(-26)}L${X(70)} ${Y(30)}` +
    `Q${X(70)} ${Y(40)} ${X(60)} ${Y(40)}L${X(15)} ${Y(40)}Q${X(11)} ${Y(35)} ${X(0)} ${Y(34)}` +
    `Q${X(-11)} ${Y(35)} ${X(-15)} ${Y(40)}L${X(-60)} ${Y(40)}Q${X(-70)} ${Y(40)} ${X(-70)} ${Y(30)}` +
    `L${X(-70)} ${Y(-26)}Q${X(-70)} ${Y(-36)} ${X(-60)} ${Y(-36)}Z`
  )
}
