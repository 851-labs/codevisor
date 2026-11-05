import { phoneProp } from "../../src/arms/rig-draw.js"
import { flipAngle } from "../../src/effects/clipboard-reading.js"
import type { BotMascotColor, BotMascotConfig } from "../../src/index.js"
import { botMascotMoods } from "../../src/moods/moods.js"
import { renderContext, withHands } from "../../src/render/context.js"
import { renderFrame } from "../../src/render/frame.js"
import { collect, defsOf, type Item } from "./collect.js"
import { parseSvg, pathContours, type El } from "./svg.js"

const BOARD = { x0: 210, x1: 290, y0: 318, y1: 382 }
const PAGE = 56
const PY = BOARD.y0 - 9
const LEN = PAGE + 12

const role = (root: El, r: string): El | undefined => {
  if (root.attrs["data-r"] === r) return root
  for (const c of root.children) {
    const found = role(c, r)
    if (found) return found
  }
  return undefined
}

export function phoneItems(config: BotMascotConfig): Item[] {
  const svg = `<svg>${phoneProp(config.color ?? "sunny").svg}</svg>`
  const root = parseSvg(svg)
  return collect(root, defsOf(root))
}

export function clipboardItems(config: BotMascotConfig): Item[] {
  const color: BotMascotColor = config.color ?? "sunny"
  const pose = botMascotMoods.working.pose(0.6)
  const s = renderFrame(
    withHands(renderContext(), () => ""),
    color,
    pose,
    { viewBox: "0 0 500 500", uid: "cb" }
  )
  const root = parseSvg(s)
  const fx = role(root, "fx")
  return fx ? collect(fx, defsOf(root)) : []
}

export interface PageShape {
  readonly rising: boolean
  readonly visible: boolean
  readonly d: string
  readonly dim: number
}

export function pageAt(tt: number): PageShape {
  const th = flipAngle(tt)
  const c = Math.cos((th * Math.PI) / 180)
  const x0 = BOARD.x0 + 5
  const x1 = BOARD.x1 - 5
  const y1 = PY + LEN * c
  const rising = c >= 0
  const visible = th > 90
  const d = rising ? risingPage(x0, x1, y1, c) : hangingPage(x0, x1, y1)
  return { rising, visible, d, dim: Math.abs(c) < 0.98 ? 0.12 * (1 - Math.abs(c)) : 0 }
}

export const restRising = pathContours(risingPage(BOARD.x0 + 5, BOARD.x1 - 5, PY + LEN, 1))
export const restHanging = pathContours(hangingPage(BOARD.x0 + 5, BOARD.x1 - 5, PY - LEN))

function risingPage(x0: number, x1: number, y1: number, c: number): string {
  const r = 7 * (0.4 + 0.6 * c)
  return `M${x0} ${y1}L${x0} ${PY}C${x0} ${PY - r * 1.35} ${x1} ${PY - r * 1.35} ${x1} ${PY}L${x1} ${y1}Z`
}

function hangingPage(x0: number, x1: number, y1: number): string {
  return `M${x0} ${PY}L${x0} ${y1 + 6}Q${x0} ${y1} ${x0 + 6} ${y1}L${x1 - 6} ${y1}Q${x1} ${y1} ${x1} ${y1 + 6}L${x1} ${PY}Z`
}
