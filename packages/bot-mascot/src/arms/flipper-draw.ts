import type { Palette } from "../color/palette.js"
import { f2, type Point } from "../geometry/math.js"
import { LIGHT } from "../render/frame.js"
import { svgBody, svgGradientId, svgTransform, svgUid } from "../render/svg-parts.js"
import { flipperOutline } from "./flipper-outline.js"
import type { FlipperArm } from "./flipper.js"

const BOX = 'x="-100" y="-100" width="700" height="700"'
const NUDGE = `translate(${LIGHT[0]} ${LIGHT[1]})`

export function drawFlippersOver(
  svg: string,
  P: Palette,
  arms: ReadonlyArray<FlipperArm>,
  idp = "ma"
): string {
  const body = svgBody(svg)
  const tf = svgTransform(svg)
  const grad = svgGradientId(svg)
  let defs = ""
  let out = ""
  arms.forEach((a, i) => {
    const { edge, fill, joins } = flipperOutline(body, a)
    const id = `${idp}${i}`
    defs +=
      jointDefs(id, a, joins, body) +
      `<clipPath id="${id}c"><path d="${fill}"/></clipPath>` +
      `<mask id="${id}s" maskUnits="userSpaceOnUse" ${BOX}><rect ${BOX} fill="#fff"/><g fill="#000" transform="${NUDGE}"><path d="${fill}"/><path d="${body}"/></g></mask>` +
      `<mask id="${id}o" maskUnits="userSpaceOnUse" ${BOX}><rect ${BOX} fill="#fff"/><path d="${body}" fill="#000"/></mask>` +
      `<clipPath id="${id}b"><path d="${body}"/></clipPath>` +
      `<mask id="${id}bs" maskUnits="userSpaceOnUse" ${BOX}><rect ${BOX} fill="#fff"/><path d="${body}" fill="#000" transform="${NUDGE}"/></mask>`
    out +=
      outlineStroke(P, edge, id) +
      `<path d="${fill}" fill="url(#${grad})"/>` +
      `<g clip-path="url(#${id}c)"><g mask="url(#${id}o)"><rect ${BOX} fill="${P.shade}" mask="url(#${id}s)"/></g>` +
      `<g clip-path="url(#${id}b)"><rect ${BOX} fill="${P.shade}" mask="url(#${id}bs)"/></g></g>`
  })
  return svg.replace(/<\/svg>$/, `<defs>${defs}</defs><g transform="${tf}">${out}</g></svg>`)
}

export function drawFlippersInBody(
  svg: string,
  P: Palette,
  arms: ReadonlyArray<FlipperArm>,
  idp = "mb"
): string {
  const body = svgBody(svg)
  const uid = svgUid(svg)
  let defs = ""
  let strokes = ""
  let fills = ""
  arms.forEach((a, i) => {
    const { edge, fill, joins } = flipperOutline(body, a)
    const id = `${idp}${i}`
    defs += jointDefs(id, a, joins, body)
    strokes += outlineStroke(P, edge, id)
    fills += `<path d="${fill}" fill="url(#${uid}g)"/>`
    if (a.front || !a.noShade) {
      defs += `<clipPath id="${id}fc"><path d="${fill}"/></clipPath><mask id="${id}fs" maskUnits="userSpaceOnUse" ${BOX}><rect ${BOX} fill="#fff"/><path d="${fill}" fill="#000" transform="${NUDGE}"/></mask>`
      fills += `<g clip-path="url(#${id}fc)"><rect ${BOX} fill="${P.shade}" mask="url(#${id}fs)"/></g>`
    }
  })
  const pass = `<g clip-path="url(#${uid}c)"><rect x="40" y="20" width="420" height="460" fill="${P.shade}" mask="url(#${uid}m)"/></g>`
  return svg.replace("</defs>", `${defs}</defs>`).replace(pass, pass + strokes + fills)
}

function outlineStroke(P: Palette, edge: string, id: string): string {
  return `<path d="${edge}" fill="none" stroke="${P.outline}" stroke-width="16" stroke-linecap="round" stroke-linejoin="round" mask="url(#${id}m)"/>`
}

function jointDefs(
  id: string,
  a: FlipperArm,
  joins: readonly [Point, Point],
  body: string
): string {
  const circles = joins
    .map(([x, y]) => `<circle cx="${f2(x)}" cy="${f2(y)}" r="${a.front ? 12 : 10}"/>`)
    .join("")
  const fade = a.front && a.softRoot ? frontFade(joins, id, body) : ""
  return (
    `<clipPath id="${id}j">${circles}</clipPath>` +
    `<mask id="${id}m" maskUnits="userSpaceOnUse" ${BOX}><rect ${BOX} fill="#fff"/><path d="${body}" fill="#000" clip-path="url(#${id}j)"/>${fade}</mask>`
  )
}

function frontFade(joins: readonly [Point, Point], id: string, body: string): string {
  return (
    `<defs><radialGradient id="${id}rg"><stop offset="0.35" stop-color="#000"/><stop offset="1" stop-color="#000" stop-opacity="0"/></radialGradient>` +
    `<clipPath id="${id}rb"><path d="${body}"/></clipPath></defs><g clip-path="url(#${id}rb)">${joins.map(([x, y]) => `<circle cx="${f2(x)}" cy="${f2(y)}" r="24" fill="url(#${id}rg)"/>`).join("")}</g>`
  )
}
