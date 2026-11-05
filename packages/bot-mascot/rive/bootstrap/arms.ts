import type { CarryLayer } from "../../src/animations/working-flip.js"
import { HAND } from "../../src/arms/prop-hand.js"
import { restArm } from "../../src/arms/rig-arm.js"
import { botMascotOutfits } from "../../src/index.js"
import { renderContext } from "../../src/render/context.js"
import { LIGHT, renderFrame } from "../../src/render/frame.js"
import { svgBody } from "../../src/render/svg-parts.js"
import { ARM_VERTICES } from "./arm-shape.js"
import { withAlpha, type Paint, type Pt } from "./collect.js"
import { bindMain, prop, solo } from "./data.js"
import { f, newId, pointsPath } from "./emit.js"
import { armJoins, LINE_SLOTS, type ArmJoin } from "./joins.js"
import { CLOTH_POINTS, sleeveOutfits } from "./sleeves.js"
import type { Contour } from "./svg.js"

export type Side = "left" | "right"

export interface LineIds {
  readonly stroke: string
  readonly trim: string
}

export interface ArmIds {
  readonly shape: string
  readonly vertices: ReadonlyArray<string>
  readonly lines: ReadonlyArray<LineIds>
  readonly rules: string
  readonly shade: string
  readonly shadeVertices: ReadonlyArray<string>
}

export interface HandIds {
  readonly node: string
}

export interface ArmPaints {
  readonly fill: Paint
  readonly fillBinds: ReadonlyArray<string>
  readonly outline: string
  readonly outlineBind: string
  readonly shade: string
  readonly shadeBind: string
}

export interface SleeveIds {
  readonly node: string
  readonly cloth: ReadonlyArray<string>
  readonly seam: ReadonlyArray<string>
  readonly cuff: ReadonlyArray<string>
  readonly seamStroke: string
  readonly cuffStroke: string
}

export interface SleevePaint {
  readonly color: string
  readonly bind: string
}

export interface ClipboardDrawables {
  readonly top: string
  readonly bottom: string
}

export interface ArmRig {
  readonly hand: string
  readonly arms: string
}

const OUTLINE = 16

const sign: Readonly<Record<Side, number>> = { left: -1, right: 1 }
const HAND_POINTS = 48

const sideIds = (): ArmIds => ({
  shape: newId(),
  vertices: Array.from({ length: ARM_VERTICES }, () => newId()),
  lines: Array.from({ length: LINE_SLOTS }, () => ({ stroke: newId(), trim: newId() })),
  rules: newId(),
  shade: newId(),
  shadeVertices: Array.from({ length: ARM_VERTICES }, () => newId())
})

export const armIds: Readonly<Record<Side, ArmIds>> = { left: sideIds(), right: sideIds() }
export const handIds: HandIds = { node: newId() }

const sleeveIdsFor = (): SleeveIds => ({
  node: newId(),
  cloth: Array.from({ length: CLOTH_POINTS }, () => newId()),
  seam: [newId(), newId()],
  cuff: [newId(), newId()],
  seamStroke: newId(),
  cuffStroke: newId()
})

export const sleeveIds: Readonly<Record<Side, ReadonlyMap<string, SleeveIds>>> = {
  left: new Map(sleeveOutfits.map((o) => [o.id, sleeveIdsFor()])),
  right: new Map(sleeveOutfits.map((o) => [o.id, sleeveIdsFor()]))
}
export const layerTargets: Readonly<Record<CarryLayer, string>> = {
  front: newId(),
  behind: newId(),
  between: newId()
}

export function armRig(
  paints: ArmPaints,
  clipboard: ClipboardDrawables,
  sleeves: ReadonlyMap<string, SleevePaint>
): ArmRig {
  const body = restBody()
  const arms = (["right", "left"] as const).map((side) => {
    const rest = restJoin(body, side)
    const rules = side === "right" ? drawRules(clipboard) : ""
    const shade = side === "left" ? shadeXml(rest.contour, paints) : ""
    return sleevesXml(side, paints, sleeves) + shade + armXml(side, rest.contour, paints, rules)
  })
  return { hand: handXml(paints), arms: arms.join("\n") }
}

const shoulderY = (): number => renderContext().body.shoulderY

export const restBody = (): string =>
  svgBody(renderFrame(renderContext(), "sunny", {}, { viewBox: "0 0 500 500", uid: "a" }))

export const restJoin = (body: string, side: Side): ArmJoin => {
  const arm = restArm({ d: body, shoulderY: shoulderY() }, sign[side], 0)
  return armJoins(body, [{ side: sign[side], arm }])[0]
}

export const ink = (paints: ArmPaints, effect = "", cap = "round", id = newId()) =>
  `<Stroke thickness="${OUTLINE}" cap="${cap}" join="round" name="Ink" id="${id}"><SolidColor colorValue="${paints.outline}" name="C">${paints.outlineBind}</SolidColor>${effect}</Stroke>`

function armXml(side: Side, rest: Contour, paints: ArmPaints, rules: string): string {
  const ids = armIds[side]
  const strokes = ids.lines
    .map((line) =>
      ink(
        paints,
        `<TrimPath start="0" end="0" name="Line" id="${line.trim}"/>`,
        "round",
        line.stroke
      )
    )
    .join("")
  return `<Shape opacity="0" name="Arm ${side}" id="${ids.shape}">${pointsPath(rest, [...ids.vertices])}${strokes}<Fill name="Fill">${gradientXml(paints.fill, paints.fillBinds, [0, 0])}</Fill>${rules}</Shape>`
}

function drawRules(clipboard: ClipboardDrawables): string {
  const target = (layer: CarryLayer, drawable: string, placement: "before" | "after") =>
    `<DrawTarget drawableId="${drawable}" placementValue="${placement}" name="${layer}" id="${layerTargets[layer]}"/>`
  return `<DrawRules drawTargetId="${layerTargets.front}" name="Layer" id="${armIds.right.rules}">${target("front", armIds.left.shade, "before")}${target("between", clipboard.top, "before")}${target("behind", clipboard.bottom, "after")}</DrawRules>`
}

const FRAME = [
  [-200, -200],
  [700, -200],
  [700, 700],
  [-200, 700]
]

function shadeXml(rest: Contour, paints: ArmPaints): string {
  const ids = armIds.left
  const frame = FRAME.map(([x, y]) => `<StraightVertex x="${x}" y="${y}"/>`).join("")
  const shifted = pointsPath(rest, [...ids.shadeVertices]).replace(
    "<PointsPath ",
    `<PointsPath x="${LIGHT[0]}" y="${LIGHT[1]}" `
  )
  return `<Shape opacity="0" name="Arm shade left" id="${ids.shade}"><PointsPath isClosed="true" name="Frame">${frame}</PointsPath>${shifted}<Fill fillRule="evenOdd" name="Shade"><SolidColor colorValue="${paints.shade}" name="C">${paints.shadeBind}</SolidColor></Fill><ClippingShape sourceId="${ids.shape}" name="Inside the arm"/></Shape>`
}

function sleevesXml(
  side: Side,
  paints: ArmPaints,
  sleeves: ReadonlyMap<string, SleevePaint>
): string {
  const children = botMascotOutfits.map((o) => sleeveChild(side, o.id, paints, sleeves))
  return solo(`Sleeves ${side}`, prop.outfit, bindMain, [emptyNode("none"), ...children])
}

interface SoloChild {
  readonly id: string
  readonly xml: string
}

function sleeveChild(
  side: Side,
  outfitId: string,
  paints: ArmPaints,
  sleeves: ReadonlyMap<string, SleevePaint>
): SoloChild {
  const ids = sleeveIds[side].get(outfitId)
  const outfit = sleeveOutfits.find((s) => s.id === outfitId)
  const paint = sleeves.get(outfitId)
  if (!ids || !outfit || !paint) return emptyNode(outfitId)
  return { id: ids.node, xml: sleeveXml(outfitId, side, ids, outfit.cuff, paint, paints) }
}

const emptyNode = (name: string): SoloChild => {
  const id = newId()
  return { id, xml: `<Node name="${name}" id="${id}"/>` }
}

const line = (vertices: ReadonlyArray<string>): string =>
  `<PointsPath isClosed="false" name="Path">${vertices.map((v) => `<StraightVertex x="0" y="0" id="${v}"/>`).join("")}</PointsPath>`

function sleeveXml(
  outfitId: string,
  side: Side,
  ids: SleeveIds,
  cuff: string,
  paint: SleevePaint,
  paints: ArmPaints
): string {
  const clip = `<ClippingShape sourceId="${armIds[side].shape}" name="Inside the arm"/>`
  const seam = `<Shape name="Seam" id="${newId()}">${line(ids.seam)}<Stroke thickness="3.5" cap="round" name="Seam" id="${ids.seamStroke}"><SolidColor colorValue="${paints.outline}" name="C">${paints.outlineBind}</SolidColor></Stroke>${clip}</Shape>`
  const cuffXml = cuff
    ? `<Shape name="Cuff" id="${newId()}">${line(ids.cuff)}<Stroke thickness="6" cap="butt" name="Cuff" id="${ids.cuffStroke}"><SolidColor colorValue="${withAlpha(cuff, 1)}" name="C"/></Stroke>${clip}</Shape>`
    : ""
  const cloth = `<Shape name="Cloth" id="${newId()}"><PointsPath isClosed="true" name="Path">${ids.cloth.map((v) => `<StraightVertex x="0" y="0" id="${v}"/>`).join("")}</PointsPath><Fill name="Fill"><SolidColor colorValue="${paint.color}" name="C">${paint.bind}</SolidColor></Fill>${clip}</Shape>`
  return `<Node opacity="0" name="${outfitId}" id="${ids.node}">${seam}${cuffXml}${cloth}</Node>`
}

const HAND_AT: Pt = [330, 250]

function handXml(paints: ArmPaints): string {
  const contour: Contour = { closed: true, vertices: handOutline().map((p) => ({ p })) }
  const fill = `<Fill name="Fill">${gradientXml(paints.fill, paints.fillBinds, HAND_AT)}</Fill>`
  return `<Node opacity="0" name="Hand" id="${handIds.node}"><Shape name="Hand shape" id="${newId()}">${pointsPath(
    contour,
    contour.vertices.map(() => newId())
  )}${ink(paints)}${fill}</Shape></Node>`
}

function handOutline(): Pt[] {
  const round = 2 / HAND.round
  return Array.from({ length: HAND_POINTS }, (_, k) => {
    const t = (2 * Math.PI * k) / HAND_POINTS
    const c = Math.cos(t)
    const s = Math.sin(t)
    return [
      (Math.sign(c) * Math.abs(c) ** round * HAND.len) / 2,
      (Math.sign(s) * Math.abs(s) ** round * HAND.w) / 2
    ]
  })
}

export function gradientXml(paint: Paint, binds: ReadonlyArray<string>, at: Pt): string {
  if (paint.kind !== "linear") return `<SolidColor colorValue="FFFFFFFF" name="C"/>`
  const stops = paint.stops
    .map(
      (s, i) =>
        `<GradientStop colorValue="${s.color}" position="${f(s.offset)}">${binds[i] ?? ""}</GradientStop>`
    )
    .join("")
  return `<LinearGradient startX="${f(paint.start[0] - at[0])}" startY="${f(paint.start[1] - at[1])}" endX="${f(paint.end[0] - at[0])}" endY="${f(paint.end[1] - at[1])}" name="G">${stops}</LinearGradient>`
}
