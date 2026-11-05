import type { Colorable } from "../color/colors.js"
import type { Palette } from "../color/palette.js"
import { f2 } from "../geometry/math.js"
import { anaglyph } from "./anaglyph.js"
import { lensOf, type EyewearDrawing } from "./eyewear-lens.js"
import type { FaceState } from "./face-state.js"
import { monocle, shades, specs } from "./glasses.js"
import { goggles, nightVision, welder } from "./goggles.js"
import { safety } from "./safety-goggles.js"

export interface EyewearItem extends Colorable {
  readonly title: string
  readonly hidesBrow?: boolean
  readonly draw: EyewearDrawing
}

export const eyewearItems = {
  specs: { title: "Round specs", draw: specs },
  monocle: { title: "Monocle", draw: monocle },
  goggles: { title: "Ski goggles", colors: "fabric", auto: true, hidesBrow: true, draw: goggles },
  safety: { title: "Safety goggles", hidesBrow: true, draw: safety },
  shades: { title: "Sport shades", colors: "fabric", auto: true, draw: shades },
  anaglyph: { title: "3D glasses", draw: anaglyph },
  welder: { title: "Welding goggles", hidesBrow: true, draw: welder },
  nightVision: { title: "Night vision goggles", hidesBrow: true, draw: nightVision }
} as const satisfies Readonly<Record<string, EyewearItem>>

export type EyewearKind = keyof typeof eyewearItems

export const isEyewearKind = (kind: string | undefined): kind is EyewearKind =>
  kind !== undefined && Object.hasOwn(eyewearItems, kind)

export const eyewearItem = (kind: string | undefined): EyewearItem | undefined =>
  isEyewearKind(kind) ? eyewearItems[kind] : undefined

export function eyewearSvg(P: Palette, f: FaceState, uid: string): string {
  const item = eyewearItem(f.eyewear)
  const op = f.eyewearOp ?? 1
  if (!item || op <= 0.01) return ""

  const out = item.draw(lensOf(P, f, uid))
  return op < 0.999 ? `<g opacity="${f2(op)}">${out}</g>` : out
}
