import { CREAM, GOLD, litGradient, mix } from "../color/colors.js"
import { bodyBottom, bodyTop, type Palette } from "../color/palette.js"
import { clamp, f2 } from "../geometry/math.js"
import type { HatPose } from "../pose.js"
import { arcD, glint, star5 } from "../render/shine.js"

const strokeOf = (P: Palette, width: number): string =>
  `stroke="${P.outline}" stroke-width="${width}" stroke-linejoin="round" paint-order="stroke"`

const PARTY_DOTS: ReadonlyArray<readonly [number, number, number]> = [
  [-11, -14, 5.5],
  [12, -30, 4.5],
  [-4, -50, 3.5],
  [16, -6, 4.5],
  [-12, -34, 3.5]
]

export function beanie(P: Palette, A: string, id: string): string {
  const S = strokeOf(P, 14)
  return (
    `<defs>${litGradient(id + "a", mix(A, "#ffffff", 0.24), mix(A, "#000000", 0.06))}${litGradient(id + "b", A, mix(A, "#000000", 0.16))}${litGradient(id + "p", mix(A, "#ffffff", 0.6), mix(A, "#ffffff", 0.2))}</defs>` +
    `<circle cx="0" cy="-72" r="17" fill="url(#${id}p)" ${S}/>` +
    `<path d="M-86 8C-90 -40 -48 -62 0 -62C48 -62 90 -40 86 8Z" fill="url(#${id}a)" ${S}/>` +
    `<path d="M-98 0Q0 -12 98 0L99 26Q0 38 -99 26Z" fill="url(#${id}b)" ${S}/>` +
    beanieRibs(mix(A, P.outline.slice(0, 7), 0.4))
  )
}

export function partyHat(P: Palette, A: string, id: string): string {
  const S = strokeOf(P, 14)
  const dots = PARTY_DOTS.map(
    ([x, y, r]) => `<circle cx="${x}" cy="${y}" r="${r}" fill="${CREAM}"/>`
  ).join("")
  return (
    `<defs>${litGradient(id + "a", mix(A, "#ffffff", 0.22), mix(A, "#000000", 0.12))}</defs><g transform="translate(18 0) rotate(14)">` +
    `<path d="M-32 2L-3 -74Q0 -79 3 -74L32 2Q0 12 -32 2Z" fill="url(#${id}a)" ${S}/>` +
    dots +
    `<circle cx="0" cy="-81" r="12" fill="${mix(A, "#ffffff", 0.5)}" ${S}/></g>`
  )
}

export function antenna(P: Palette, _A: string, id: string, hat: HatPose): string {
  const O = P.outline
  const skin = bodyTop(P).slice(0, 7)
  const deep = bodyBottom(P).slice(0, 7)
  const sway = 40 * Math.tanh((hat.tipX || 0) / 40)
  const bob = 16 * Math.tanh(((hat.tipY || 0) * 0.8) / 16)
  const tx = sway
  const ty = -60 + bob + Math.abs(sway) * 0.32
  const d = `M0 6C0 ${f2(-24 + bob * 0.3)} ${f2(sway * 0.3)} ${f2(-46 + bob * 0.7)} ${f2(tx)} ${f2(ty)}`
  return (
    `<defs><clipPath id="${id}o"><rect x="-120" y="-200" width="240" height="198"/></clipPath>` +
    `<radialGradient id="${id}b" cx=".64" cy=".34" r=".8"><stop offset="0" stop-color="${mix(skin, "#ffffff", 0.35)}"/><stop offset="1" stop-color="${deep}"/></radialGradient></defs>` +
    `<g clip-path="url(#${id}o)"><path d="${d}" fill="none" stroke="${O}" stroke-width="18" stroke-linecap="butt"/></g>` +
    `<path d="${d}" fill="none" stroke="${skin}" stroke-width="9.5" stroke-linecap="butt"/>` +
    `<circle cx="${f2(tx)}" cy="${f2(ty)}" r="14" fill="url(#${id}b)" stroke="${O}" stroke-width="12" paint-order="stroke"/>` +
    glint(arcD(tx, ty, 8.6, 8.6, -82, -24), 3.2)
  )
}

export function wizardHat(P: Palette, A: string, id: string, hat: HatPose): string {
  const S = strokeOf(P, 13)
  const flop = clamp(-(hat.rot || 0) * 2.2, -14, 14)
  const fy = clamp((hat.dy || 0) * 0.6, -10, 0)
  const tx = 54 + flop
  const ty = -80 + fy * 0.5
  const cone =
    `M-48 -4C-40 -36 -24 -70 -2 -94C10 -106 34 -104 ${f2(tx - 6)} ${f2(ty - 12)}C${f2(tx + 2)} ${f2(ty - 8)} ${f2(tx + 2)} ${f2(ty + 2)} ${f2(tx - 2)} ${f2(ty + 6)}` +
    `C${f2(tx - 10)} ${f2(ty)} ${f2(26 + flop * 0.3)} -88 16 -80C26 -56 40 -28 48 -4Z`
  return (
    `<defs>${litGradient(id + "c", mix(A, "#ffffff", 0.2), mix(A, "#000000", 0.14))}${litGradient(id + "b", mix(A, "#ffffff", 0.1), mix(A, "#000000", 0.22))}</defs>` +
    `<path d="${cone}" fill="url(#${id}c)" ${S}/>` +
    `<path d="M-46 -2C-40 -9 40 -9 46 -2L44 -16C30 -22 -30 -22 -44 -16Z" fill="${GOLD}" ${strokeOf(P, 7)}/>` +
    star5(P, -14, -46, 7.5, "#F5C842", 8) +
    star5(P, 12, -66, 5.5, "#F5C842", -12) +
    star5(P, 24, -32, 4.5, "#F5C842", 20) +
    `<path d="M-102 2C-100 -12 -60 -16 0 -16C60 -16 100 -12 102 2C100 14 60 18 0 18C-60 18 -100 14 -102 2Z" fill="url(#${id}b)" ${S}/>`
  )
}

function beanieRibs(rib: string): string {
  let ribs = ""
  for (let x = -84; x <= 84; x += 14) {
    const y1 = -6 * (1 - (x / 98) ** 2) + 7
    const y2 = 26 + 6 * (1 - (x / 99) ** 2) - 7
    ribs += `<path d="M${x} ${y1.toFixed(1)}L${x} ${y2.toFixed(1)}" stroke="${rib}" stroke-opacity=".55" stroke-width="4" stroke-linecap="round"/>`
  }
  return ribs
}
