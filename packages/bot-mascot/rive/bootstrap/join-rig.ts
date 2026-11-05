import { gradientXml, ink, restBody, restJoin, type ArmPaints, type Side } from "./arms.js"
import { newId, pointsPath } from "./emit.js"
import { UNION_LINE_POINTS, UNION_POINTS } from "./joins.js"
import type { Contour } from "./svg.js"
import { heldObjects } from "./tracks.js"

export interface JoinIds {
  readonly shape: string
  readonly vertices: ReadonlyArray<string>
  readonly lineVertices: ReadonlyArray<string>
}

export interface JoinRig {
  readonly joins: string
}

const joinIdsFor = (): JoinIds => ({
  shape: newId(),
  vertices: Array.from({ length: UNION_POINTS }, () => newId()),
  lineVertices: Array.from({ length: UNION_LINE_POINTS }, () => newId())
})

export const joinIds: Readonly<Record<Side, JoinIds>> = { left: joinIdsFor(), right: joinIdsFor() }

for (const side of [joinIds.left, joinIds.right]) {
  for (const id of [...side.vertices, ...side.lineVertices]) heldObjects.add(id)
}

export function joinRig(paints: ArmPaints): JoinRig {
  const body = restBody()
  const joins = (["right", "left"] as const).map((side) => joinXml(side, body, paints)).join("\n")
  return { joins }
}

const placeholder = (closed: boolean, count: number): Contour => ({
  closed,
  vertices: Array.from({ length: count }, () => ({
    p: [250, 300],
    inH: [250, 300],
    outH: [250, 300]
  }))
})

function joinXml(side: Side, body: string, paints: ArmPaints): string {
  const ids = joinIds[side]
  const rest = restJoin(body, side).union
  const contour = rest?.contour ?? placeholder(true, UNION_POINTS)
  const line = rest?.line ?? placeholder(false, UNION_LINE_POINTS)
  const fill = `<Fill name="Fill">${gradientXml(paints.fill, paints.fillBinds, [0, 0])}</Fill>`
  const lineShape = `<Shape name="Line">${pointsPath(line, [...ids.lineVertices])}${ink(paints, "", "butt")}</Shape>`
  return `<Node opacity="0" name="Join ${side}" id="${ids.shape}"><Shape name="Fill">${pointsPath(contour, [...ids.vertices])}${fill}</Shape>${lineShape}</Node>`
}
