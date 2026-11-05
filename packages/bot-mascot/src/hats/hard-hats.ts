import { INK, litGradient } from "../color/colors.js"
import type { Palette } from "../color/palette.js"
import { f2 } from "../geometry/math.js"
import type { HatPose } from "../pose.js"
import { arcD, glint, glintDot } from "../render/shine.js"

const strokeOf = (P: Palette, width: number): string =>
  `stroke="${P.outline}" stroke-width="${width}" stroke-linejoin="round" paint-order="stroke"`

export function propellerCap(P: Palette, _A: string, id: string, hat: HatPose): string {
  const dome = "M-62 8C-62 -38 -34 -56 0 -56C34 -56 62 -38 62 8Q0 17 -62 8Z"
  const phi = hat.spin ?? 0.6
  const c = Math.cos(phi)
  const blade = (sg: number, col: string): string => {
    const X = (u: number): string => f2(sg * c * u)
    return `<path d="M${X(5)} -73C${X(12)} -82 ${X(30)} -81 ${X(36)} -73C${X(30)} -66 ${X(12)} -65 ${X(5)} -73Z" fill="${col}" ${strokeOf(P, 8)}/>`
  }
  const red = blade(1, "#FF5B5B")
  const blue = blade(-1, "#4C8DFF")
  const [back, front] = Math.sin(phi) >= 0 ? [blue, red] : [red, blue]
  return (
    `<clipPath id="${id}c"><path d="${dome}"/></clipPath>` +
    `<path d="M0 -56L0 -70" stroke="${P.outline}" stroke-width="9" stroke-linecap="round"/><path d="M0 -56L0 -70" stroke="#D5D9E2" stroke-width="3.5" stroke-linecap="round"/>` +
    back +
    `<circle cx="0" cy="-73" r="6.5" fill="#FFD23F" ${strokeOf(P, 8)}/>` +
    front +
    `<path d="${dome}" fill="#FF5B5B" ${strokeOf(P, 14)}/><g clip-path="url(#${id}c)">` +
    `<path d="M0 -60C-24 -44 -24 -6 -20 20L20 20C24 -6 24 -44 0 -60Z" fill="#FFD23F"/>` +
    `<path d="M0 -60C24 -44 24 -6 20 20L80 20L80 -80L0 -80Z" fill="#4C8DFF"/>` +
    glint("M14 -50C30 -48 44 -38 50 -22") +
    `</g>` +
    `<path d="M0 -60C-24 -44 -24 -6 -20 20M0 -60C24 -44 24 -6 20 20" fill="none" stroke="${P.outline}" stroke-width="4" stroke-opacity=".6"/>` +
    `<path d="${dome}" fill="none" stroke="${P.outline}" stroke-width="6" stroke-linejoin="round"/>`
  )
}

export function crown(P: Palette, _A: string, id: string): string {
  const S = strokeOf(P, 12)
  const tips = [
    [-48, -36],
    [0, -50],
    [48, -36]
  ]
    .map(([x, y]) => `<circle cx="${x}" cy="${y}" r="6.5" fill="url(#${id}g)" ${S}/>`)
    .join("")
  return (
    `<defs>${litGradient(id + "g", "#FFE68C", "#E9A62A")}</defs>` +
    tips +
    `<path d="M-46 10L-48 -34L-24 -12L0 -48L24 -12L48 -34L46 10Q0 18 -46 10Z" fill="url(#${id}g)" ${S}/>` +
    `<path d="M-46 -4Q0 3 46 -4" fill="none" stroke="${P.outline}" stroke-width="3.5" stroke-opacity=".5"/>` +
    `<circle cx="0" cy="4" r="6" fill="#E5484D" stroke="${P.outline}" stroke-width="3"/>` +
    `<circle cx="-28" cy="3" r="4.2" fill="#4F7BFF" stroke="${P.outline}" stroke-width="3"/><circle cx="28" cy="3" r="4.2" fill="#3FBF7F" stroke="${P.outline}" stroke-width="3"/>` +
    glint("M29 -10Q36 -15 39 -22", 3.5) +
    glintDot(40, -12, 1.9)
  )
}

export function topHat(P: Palette, A: string, id: string): string {
  const S = strokeOf(P, 14)
  return (
    `<defs>${litGradient(id + "a", "#50525F", "#202128")}</defs>` +
    `<path d="M-37 2L-33 -78Q0 -84 33 -78L37 2Z" fill="url(#${id}a)" ${S}/>` +
    `<path d="M-35.8 -22Q0 -17 35.8 -22L37 2L-37 2Z" fill="${A}"/>` +
    `<path d="M-35.8 -22Q0 -17 35.8 -22" fill="none" stroke="${P.outline}" stroke-width="3.5" stroke-opacity=".6"/>` +
    glint("M8 -13Q21 -14 31 -16.5", 3.2) +
    `<path d="M-64 4Q-66 -6 -40 -2L40 -2Q66 -6 64 4Q0 18 -64 4Z" fill="url(#${id}a)" ${S}/>`
  )
}

export function pumpkin(P: Palette, _A: string, id: string): string {
  const O = P.outline
  const cap =
    "M-58 4C-62 -28 -34 -50 0 -50C34 -50 62 -28 58 4L50 10L40 -8L30 12L18 -10L6 12L-6 -10L-18 12L-30 -8L-42 12L-52 6Z"
  const eye = (d: string): string =>
    `<path d="${d}" fill="#6B1E0E" stroke="${O}" stroke-width="3.5" stroke-linejoin="round"/>`
  return (
    `<defs>${litGradient(id + "o", "#FFA43A", "#E0620F")}${litGradient(id + "s", "#8E9440", "#56611F")}<clipPath id="${id}c"><path d="${cap}"/></clipPath></defs><g transform="translate(-2 0) rotate(-12)">` +
    `<path d="${cap}" fill="url(#${id}o)" stroke="${O}" stroke-width="12" stroke-linejoin="round" paint-order="stroke"/>` +
    `<g clip-path="url(#${id}c)">` +
    glint("M16 -44Q34 -40 44 -26", 4.5) +
    rib("M-22 -48Q-38 -22 -30 10") +
    rib("M22 -48Q38 -22 30 10") +
    rib("M0 -50Q4 -36 2 -26") +
    `</g>` +
    eye("M-36 -14L-24 -34L-12 -16Z") +
    eye("M12 -16L26 -36L36 -14Z") +
    `<path d="M-13 -46C-9 -52 -7 -60 -6 -68C-5 -73 -1 -77 5 -78L16 -75C14 -69 11 -62 11 -55C11 -51 13 -48 16 -46Q2 -41 -13 -46Z" fill="url(#${id}s)" stroke="${O}" stroke-width="10" stroke-linejoin="round" paint-order="stroke"/>` +
    `<ellipse cx="10.5" cy="-76.5" rx="6" ry="2.6" transform="rotate(16 10.5 -76.5)" fill="#C9C27A" stroke="${O}" stroke-width="3"/>` +
    `<path d="M-1 -48C1 -56 2 -64 4 -72M6 -47C6 -55 7 -63 9 -71" fill="none" stroke="#3F4A1C" stroke-width="2.4" stroke-linecap="round" stroke-opacity=".7"/>` +
    `</g>`
  )
}

export function hardHat(P: Palette, _A: string, id: string): string {
  const dome = "M-56 6C-56 -38 -32 -60 0 -60C32 -60 56 -38 56 6Q0 14 -56 6Z"
  const ridge = "M-11 -59C-13 -40 -13 -16 -11 9L11 9C13 -16 13 -40 11 -59Q0 -61.5 -11 -59Z"
  return (
    `<defs>${litGradient(id + "y", "#FFD84D", "#F4A21A")}${litGradient(id + "r", "#FFE680", "#F7B52A")}<clipPath id="${id}c"><path d="${dome}"/></clipPath></defs>` +
    `<path d="${dome}" fill="url(#${id}y)" ${strokeOf(P, 14)}/>` +
    `<g clip-path="url(#${id}c)">` +
    `<path d="${ridge}" fill="url(#${id}r)"/>` +
    rib("M-30 -53Q-44 -28 -42 8", "#C9770E") +
    rib("M30 -53Q44 -28 42 8", "#C9770E") +
    glint("M16 -48Q32 -44 42 -30") +
    `</g>` +
    `<path d="M-11 -59C-13 -40 -13 -16 -11 9M11 -59C13 -40 13 -16 11 9" fill="none" stroke="${P.outline}" stroke-width="3.5" stroke-opacity=".55"/>` +
    `<path d="${dome}" fill="none" stroke="${P.outline}" stroke-width="6" stroke-linejoin="round"/>` +
    `<path d="M-74 10Q-76 0 -56 2Q0 9 56 2Q76 0 74 10Q0 24 -74 10Z" fill="url(#${id}y)" ${strokeOf(P, 12)}/>` +
    glint("M38 9Q52 8 62 6", 3.2)
  )
}

export function rubberDuck(P: Palette, _A: string, id: string): string {
  const S = strokeOf(P, 12)
  return (
    `<defs>${litGradient(id + "y", "#FFE36B", "#F5B71C")}</defs>` +
    `<path d="M-38 2C-40 -20 -20 -28 0 -24C14 -22 28 -32 36 -20C42 -8 34 6 20 8Q0 12 -30 8C-36 7 -38 5 -38 2Z" fill="url(#${id}y)" ${S}/>` +
    `<circle cx="-14" cy="-42" r="18" fill="url(#${id}y)" ${S}/>` +
    `<path d="M-30 -42C-42 -44 -47 -37 -40 -33C-36 -31 -30 -33 -28 -36Z" fill="#FF8A2B" ${strokeOf(P, 9)}/>` +
    `<circle cx="-19" cy="-46" r="3.4" fill="${INK}"/><circle cx="-18" cy="-47.2" r="1.1" fill="#fff"/>` +
    `<path d="M-2 -12C8 -20 22 -16 24 -6C14 -2 4 -4 -2 -12Z" fill="#F5B71C" stroke="${P.outline}" stroke-width="3" stroke-opacity=".5"/>` +
    glint(arcD(-14, -42, 11.5, 11.5, -76, -24), 3.6)
  )
}

const rib = (d: string, color = "#B4400F"): string =>
  `<path d="${d}" fill="none" stroke="${color}" stroke-width="4" stroke-linecap="round" stroke-opacity=".85"/>`
