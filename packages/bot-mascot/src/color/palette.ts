import { data, type RawPalette } from "../data.js"

export const botMascotColorIds = [
  "ruby",
  "tomato",
  "tangerine",
  "sunny",
  "lime",
  "clover",
  "mint",
  "aqua",
  "sky",
  "electric",
  "lilac",
  "grape",
  "orchid",
  "bubblegum",
  "dream",
  "cocoa",
  "slate",
  "classic"
] as const

export type BotMascotColor = (typeof botMascotColorIds)[number]

export const defaultBotMascotColor: BotMascotColor = "sunny"

export const botMascotColorRotation: ReadonlyArray<BotMascotColor> = [
  "sunny",
  "mint",
  "lilac",
  "bubblegum",
  "sky",
  "tomato",
  "electric",
  "dream",
  "tangerine",
  "aqua",
  "orchid",
  "lime",
  "ruby",
  "grape",
  "clover",
  "slate",
  "cocoa",
  "classic"
]

export interface Palette {
  readonly key: BotMascotColor
  readonly title: string
  readonly outline: string
  readonly eye: string
  readonly glint: string
  readonly cheek: string
  readonly shade: string
  readonly shadow: string
  readonly fx: string
  readonly body: ReadonlyArray<readonly [number, string]>
}

export const isBotMascotColor = (key: string | undefined): key is BotMascotColor =>
  botMascotColorIds.some((id) => id === key)

export const rawPalette = (key: BotMascotColor): RawPalette => data.palettes[key]!

export const palette = (key: string | undefined): Palette => {
  const resolved = isBotMascotColor(key) ? key : defaultBotMascotColor
  const src = rawPalette(resolved)
  return {
    key: resolved,
    title: src.title,
    outline: argb(src.outline),
    eye: argb(src.eye),
    glint: argb(src.glint),
    cheek: argb(src.cheek),
    shade: argb(src.shade),
    shadow: argb(src.shadow),
    fx: argb(src.fx),
    body: src.body.map(([pos, c]) => [pos, argb(c)] as const)
  }
}

export const bodyTop = (p: Palette): string => p.body[0]![1]

export const bodyBottom = (p: Palette): string => p.body[p.body.length - 1]![1]

function argb(s: string): string {
  const a = parseInt(s.slice(0, 2), 16) / 255
  const [r, g, b] = [2, 4, 6].map((i) => parseInt(s.slice(i, i + 2), 16))
  return a >= 0.999 ? `#${s.slice(2)}` : `rgba(${r},${g},${b},${a.toFixed(3)})`
}
