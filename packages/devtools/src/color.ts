export interface InstanceColor {
  readonly hex: string
  readonly composer: string
}

const saturation = 0.68
const lightness = 0.5

export function colorFromHash(hash: string): InstanceColor {
  const hue = Number.parseInt(hash.slice(0, 8), 16) % 360
  const chroma = (1 - Math.abs(2 * lightness - 1)) * saturation
  const section = hue / 60
  const x = chroma * (1 - Math.abs((section % 2) - 1))
  const [red, green, blue] = hueSectionChannels(section, chroma, x)
  const match = lightness - chroma / 2
  const channels = [red + match, green + match, blue + match]
  const bytes = channels.map((channel) => Math.round(channel * 255))
  return {
    hex: `#${bytes.map((byte) => byte.toString(16).padStart(2, "0")).join("")}`,
    composer: `extended-srgb:${channels.map((channel) => channel.toFixed(5)).join(",")},1.00000`
  }
}

function hueSectionChannels(section: number, chroma: number, x: number): [number, number, number] {
  if (section < 1) return [chroma, x, 0]
  if (section < 2) return [x, chroma, 0]
  if (section < 3) return [0, chroma, x]
  if (section < 4) return [0, x, chroma]
  if (section < 5) return [x, 0, chroma]
  return [chroma, 0, x]
}
