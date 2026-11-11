import type { BotMascotColor } from "./palette.js"

export const namedColors = {
  red: "#E5484D",
  orange: "#FF8A3D",
  yellow: "#FFC93C",
  green: "#3FBF7F",
  teal: "#2FB5B0",
  blue: "#4F7BFF",
  purple: "#8B5CF6",
  pink: "#FF6FA5",
  peach: "#FFAA80",
  cream: "#F4EEE2",
  charcoal: "#3A3F4B",
  navy: "#2B3A67",
  black: "#1D1E24",
  burgundy: "#6E2234",
  forest: "#2D5E45",
  olive: "#6B7449",
  tan: "#B89263",
  grey: "#9198A6"
} as const

export type NamedColor = keyof typeof namedColors

export type SwatchSet = "fabric" | "suit" | "blush" | "tulle" | "wizard"

export type Swatch = readonly [NamedColor, string]

const named = (...names: ReadonlyArray<NamedColor>): ReadonlyArray<Swatch> =>
  names.map((n) => [n, namedColors[n]] as const)

export const swatches: Readonly<Record<SwatchSet, ReadonlyArray<Swatch>>> = {
  fabric: named(
    "red",
    "orange",
    "yellow",
    "green",
    "teal",
    "blue",
    "purple",
    "pink",
    "cream",
    "charcoal"
  ),
  suit: named("navy", "charcoal", "black", "burgundy", "forest", "tan", "grey"),
  blush: named("pink", "peach", "red", "orange", "purple", "yellow"),
  tulle: named("pink", "purple", "blue", "teal", "yellow", "cream", "red", "charcoal"),
  wizard: named("purple", "blue", "navy", "teal", "forest", "burgundy", "charcoal", "red")
}

const autoColor: Readonly<Record<BotMascotColor, NamedColor>> = {
  sunny: "blue",
  mint: "pink",
  lilac: "yellow",
  bubblegum: "teal",
  sky: "orange",
  tomato: "blue",
  electric: "yellow",
  dream: "teal",
  ruby: "teal",
  tangerine: "blue",
  lime: "purple",
  clover: "pink",
  aqua: "orange",
  grape: "yellow",
  orchid: "green",
  cocoa: "teal",
  slate: "orange",
  classic: "red"
}

const denim: Readonly<Record<BotMascotColor, string>> = {
  sunny: "#4A6FA8",
  mint: "#4A6FA8",
  lilac: "#4A6FA8",
  bubblegum: "#4A6FA8",
  sky: "#3D4152",
  tomato: "#3F5E92",
  electric: "#3D4152",
  dream: "#4A6FA8",
  ruby: "#4A6FA8",
  tangerine: "#4A6FA8",
  lime: "#4A6FA8",
  clover: "#4A6FA8",
  aqua: "#3D4152",
  grape: "#4A6FA8",
  orchid: "#4A6FA8",
  cocoa: "#4A6FA8",
  slate: "#3D4152",
  classic: "#4A6FA8"
}

export interface WearTint {
  readonly tee: string
  readonly denim: string
}

export const hatTint = (color: BotMascotColor): string => namedColors[autoColor[color]]

export const wearTint = (color: BotMascotColor): WearTint => ({
  tee: hatTint(color),
  denim: denim[color]
})

export const INK = "#16161A"
export const GOLD = "#E9B949"
export const CREAM = "#FFF8EC"

export interface Colorable {
  readonly colors?: SwatchSet
  readonly auto?: boolean
}

export function colorOf(item: Colorable | undefined, id: string | undefined, auto: string): string
export function colorOf(
  item: Colorable | undefined,
  id: string | undefined,
  auto?: string
): string | undefined
export function colorOf(
  item: Colorable | undefined,
  id: string | undefined,
  auto?: string
): string | undefined {
  const list = item?.colors === undefined ? undefined : swatches[item.colors]
  if (list === undefined) return auto
  const hit = list.find(([k]) => k === id)
  if (hit) return hit[1]
  return item?.auto ? auto : list[0]![1]
}

export const mix = (a: string, b: string, t: number): string => {
  const ca = hex3(a)
  const cb = hex3(b)
  return (
    "#" +
    ca
      .map((v, i) =>
        Math.round(v + (cb[i]! - v) * t)
          .toString(16)
          .padStart(2, "0")
      )
      .join("")
  )
}

export const litGradient = (id: string, a: string, b: string): string =>
  `<linearGradient id="${id}" x1=".75" y1="0" x2=".25" y2="1"><stop offset="0" stop-color="${a}"/><stop offset="1" stop-color="${b}"/></linearGradient>`

const hex3 = (h: string): ReadonlyArray<number> =>
  [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16))
