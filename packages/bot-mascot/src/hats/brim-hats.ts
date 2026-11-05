import { litGradient, mix } from "../color/colors.js"
import type { Palette } from "../color/palette.js"
import { glint, glintDot } from "../render/shine.js"

const strokeOf = (P: Palette, width: number): string =>
  `stroke="${P.outline}" stroke-width="${width}" stroke-linejoin="round" paint-order="stroke"`

const line = (P: Palette, d: string, width = 3.5, opacity = 0.5): string =>
  `<path d="${d}" fill="none" stroke="${P.outline}" stroke-width="${width}" stroke-linecap="round" stroke-opacity="${opacity}"/>`

const tinted = (id: string, A: string): string =>
  litGradient(id, mix(A, "#ffffff", 0.24), mix(A, "#000000", 0.1))

const STRAW = ["#FBE29A", "#DDA94E"] as const
const STRAW_WEAVE = "#B9822F"

export function chefHat(P: Palette, _A: string, id: string): string {
  const puff =
    "M-44 -22C-70 -26 -72 -66 -44 -68C-44 -92 -14 -100 0 -84C14 -100 44 -92 44 -68C72 -66 70 -26 44 -22Z"
  return (
    `<defs>${litGradient(id + "w", "#FFFFFF", "#DCE1EA")}</defs>` +
    `<path d="${puff}" fill="url(#${id}w)" ${strokeOf(P, 14)}/>` +
    line(P, "M-22 -40Q-26 -56 -20 -66M22 -40Q26 -56 20 -66", 3.5, 0.3) +
    glint("M16 -86Q28 -90 34 -78", 3.6) +
    `<path d="M-44 6L-46 -26Q0 -32 46 -26L44 6Q0 12 -44 6Z" fill="url(#${id}w)" ${strokeOf(P, 12)}/>` +
    line(P, "M-22 -24L-22 8M0 -26L0 9M22 -24L22 8", 3, 0.3)
  )
}

export function sailorHat(P: Palette, _A: string, id: string): string {
  return (
    `<defs>${litGradient(id + "w", "#FFFFFF", "#D6DCE6")}</defs>` +
    `<path d="M-50 -6C-52 -44 -28 -60 0 -60C28 -60 52 -44 50 -6Z" fill="url(#${id}w)" ${strokeOf(P, 14)}/>` +
    line(P, "M0 -60Q-4 -34 0 -10", 3, 0.25) +
    glint("M16 -52Q34 -48 41 -32", 3.6) +
    `<path d="M-68 -2Q-72 -22 -52 -17Q0 -6 52 -17Q72 -22 68 -2Q66 13 0 15Q-66 13 -68 -2Z" fill="url(#${id}w)" ${strokeOf(P, 12)}/>` +
    `<path d="M-61 4Q0 12 61 4" fill="none" stroke="#2F57B8" stroke-width="5" stroke-linecap="round"/>`
  )
}

export function cowboyHat(P: Palette, _A: string, id: string): string {
  return (
    `<defs>${litGradient(id + "f", "#C98D52", "#86522A")}</defs>` +
    `<path d="M-40 -2L-44 -50Q-38 -64 -20 -60Q0 -50 20 -60Q38 -64 44 -50L40 -2Z" fill="url(#${id}f)" ${strokeOf(P, 14)}/>` +
    line(P, "M0 -52Q-3 -34 0 -14", 3, 0.35) +
    `<path d="M-41.6 -20Q0 -14 41.6 -20L40.6 -6Q0 0 -40.6 -6Z" fill="#4A2A14"/>` +
    glint("M22 -54Q32 -56 36 -46", 3.4) +
    `<path d="M-92 -8Q-96 -26 -78 -18Q-60 -4 -40 -6Q0 0 40 -6Q60 -4 78 -18Q96 -26 92 -8Q84 14 0 16Q-84 14 -92 -8Z" fill="url(#${id}f)" ${strokeOf(P, 12)}/>` +
    glint("M50 4Q64 0 74 -8", 3.2)
  )
}

export function conicalHat(P: Palette, _A: string, id: string): string {
  const weave = [-62, -32, 0, 32, 62].map((x) => `M0 -52L${x} ${x === 0 ? 14 : 11}`).join("")
  return (
    `<defs>${litGradient(id + "s", STRAW[0], STRAW[1])}<clipPath id="${id}c"><path d="M-94 4L0 -58L94 4Q0 22 -94 4Z"/></clipPath></defs>` +
    `<path d="M-94 4L0 -58L94 4Q0 22 -94 4Z" fill="url(#${id}s)" ${strokeOf(P, 12)}/>` +
    `<g clip-path="url(#${id}c)">` +
    `<path d="${weave}" fill="none" stroke="${STRAW_WEAVE}" stroke-width="3" stroke-opacity=".7"/>` +
    `<path d="M-60 -18Q0 -10 60 -18M-30 -38Q0 -33 30 -38" fill="none" stroke="${STRAW_WEAVE}" stroke-width="3" stroke-opacity=".55"/>` +
    `</g>` +
    glint("M12 -46Q40 -28 62 -12", 3.6)
  )
}

export function strawHat(P: Palette, _A: string, id: string): string {
  return (
    `<defs>${litGradient(id + "s", STRAW[0], STRAW[1])}</defs>` +
    `<path d="M-40 -2C-42 -38 -24 -48 0 -48C24 -48 42 -38 40 -2Z" fill="url(#${id}s)" ${strokeOf(P, 14)}/>` +
    `<path d="M-41 -18Q0 -12 41 -18L40.6 -5Q0 1 -40.6 -5Z" fill="#E5484D"/>` +
    line(P, "M-41 -18Q0 -12 41 -18M-40.6 -5Q0 1 40.6 -5", 3, 0.5) +
    glint("M14 -42Q28 -38 33 -28", 3.4) +
    `<path d="M-88 4Q-90 -8 -60 -6Q0 2 60 -6Q90 -8 88 4Q80 18 0 20Q-80 18 -88 4Z" fill="url(#${id}s)" ${strokeOf(P, 12)}/>` +
    `<path d="M-74 6Q0 15 74 6" fill="none" stroke="${STRAW_WEAVE}" stroke-width="3" stroke-opacity=".6"/>`
  )
}

export function floppyHat(P: Palette, A: string, id: string): string {
  return (
    `<defs>${tinted(id + "a", A)}</defs>` +
    `<path d="M-42 -2C-44 -40 -24 -50 0 -50C24 -50 44 -40 42 -2Z" fill="url(#${id}a)" ${strokeOf(P, 14)}/>` +
    `<path d="M-42.6 -18Q0 -12 42.6 -18L42.2 -5Q0 1 -42.2 -5Z" fill="#FFF6E5"/>` +
    line(P, "M-42.6 -18Q0 -12 42.6 -18M-42.2 -5Q0 1 42.2 -5", 3, 0.45) +
    glint("M14 -44Q30 -40 35 -30", 3.4) +
    `<path d="M-90 14C-98 0 -78 -12 -56 -6Q0 4 56 -6C78 -12 98 0 90 14C82 26 62 18 42 24Q0 32 -42 24C-62 18 -82 26 -90 14Z" fill="url(#${id}a)" ${strokeOf(P, 12)}/>` +
    line(P, "M-62 14Q0 24 62 14", 3, 0.3)
  )
}

export function beret(P: Palette, A: string, id: string): string {
  return (
    `<defs>${tinted(id + "a", A)}</defs><g transform="translate(6 0) rotate(-8)">` +
    `<path d="M4 -44L7 -54" stroke="${P.outline}" stroke-width="12" stroke-linecap="round"/><path d="M4 -44L7 -54" stroke="${mix(A, "#000000", 0.2)}" stroke-width="5" stroke-linecap="round"/>` +
    `<path d="M-66 -4C-72 -26 -40 -46 0 -46C46 -46 76 -30 68 -8C64 4 40 6 0 6C-40 6 -62 8 -66 -4Z" fill="url(#${id}a)" ${strokeOf(P, 14)}/>` +
    line(P, "M-50 0Q0 8 52 -2", 3, 0.35) +
    glint("M18 -38Q40 -36 52 -24", 3.6) +
    glintDot(58, -16, 2) +
    `</g>`
  )
}

export function bucketHat(P: Palette, A: string, id: string): string {
  return (
    `<defs>${tinted(id + "a", A)}</defs>` +
    `<path d="M-46 -4L-40 -50Q0 -58 40 -50L46 -4Z" fill="url(#${id}a)" ${strokeOf(P, 14)}/>` +
    line(P, "M-42 -28Q0 -34 42 -28", 3, 0.35) +
    glint("M16 -50Q28 -50 35 -44", 3.4) +
    `<path d="M-74 14Q-66 -4 -50 -10Q0 -2 50 -10Q66 -4 74 14Q0 27 -74 14Z" fill="url(#${id}a)" ${strokeOf(P, 12)}/>` +
    line(P, "M-62 11Q0 21 62 11", 2.8, 0.35)
  )
}
