import type { McpIcon, ToolIconTheme } from "./tool-icons.js"

export const htmlAttribute = (tag: string, name: string): string | undefined => {
  const match = new RegExp(`\\s${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s>]+))`, "i").exec(tag)
  return match === null ? undefined : (match[1] ?? match[2] ?? match[3])
}

const largestSize = (sizes: string | undefined): number | undefined => {
  if (sizes === undefined) return undefined
  if (/\bany\b/i.test(sizes)) return Number.POSITIVE_INFINITY
  const dimensions = [...sizes.matchAll(/(\d+)x(\d+)/gi)].map((match) => Number(match[1]))
  return dimensions.length === 0 ? undefined : Math.max(...dimensions)
}

const themeRank = (declared: ToolIconTheme | undefined, theme: ToolIconTheme): number => {
  if (declared === undefined) return 0
  if (declared === theme) return -5000
  return 5000
}

type RankedPageIcon = { readonly url: string; readonly rank: number; readonly order: number }

const pageIconUrl = (href: string, pageUrl: string): URL | undefined => {
  let url: URL
  try {
    url = new URL(href.replaceAll("&amp;", "&"), pageUrl)
  } catch {
    return undefined
  }
  if (url.protocol !== "https:" && url.protocol !== "http:" && url.protocol !== "data:")
    return undefined
  return url
}

const pageIconSizeRank = (tag: string, url: URL, touch: boolean): number => {
  const type = htmlAttribute(tag, "type")?.toLowerCase()
  const svg = type === "image/svg+xml" || /\.svg(?:$|\?)/i.test(url.pathname)
  const size = largestSize(htmlAttribute(tag, "sizes"))
  if (touch) return 3000
  if (svg || size === Number.POSITIVE_INFINITY) return 50
  if (size === undefined) return 2000
  if (size >= 64) return size - 64
  return 100 + (64 - size)
}

const pageIconScheme = (tag: string): ToolIconTheme | undefined => {
  const media = htmlAttribute(tag, "media")?.toLowerCase() ?? ""
  if (/prefers-color-scheme\s*:\s*dark/.test(media)) return "dark"
  if (/prefers-color-scheme\s*:\s*light/.test(media)) return "light"
  return undefined
}

const appendPageIcon = (
  tag: string,
  pageUrl: string,
  theme: ToolIconTheme,
  ranked: Array<RankedPageIcon>
): void => {
  const rel = htmlAttribute(tag, "rel")?.toLowerCase().split(/\s+/) ?? []
  const href = htmlAttribute(tag, "href")
  if (href === undefined || rel.includes("mask-icon")) return
  const touch = rel.includes("apple-touch-icon") || rel.includes("apple-touch-icon-precomposed")
  if (!touch && !rel.includes("icon")) return
  const url = pageIconUrl(href, pageUrl)
  if (url === undefined) return
  const rank = pageIconSizeRank(tag, url, touch)
  const scheme = pageIconScheme(tag)
  ranked.push({
    url: url.toString(),
    rank: rank + themeRank(scheme, theme),
    order: ranked.length
  })
}

export const pageIconCandidates = (
  html: string,
  pageUrl: string,
  theme: ToolIconTheme = "light"
): ReadonlyArray<string> => {
  const ranked: Array<RankedPageIcon> = []
  for (const match of html.matchAll(/<link\b[^>]*>/gi)) {
    const tag = match[0]
    appendPageIcon(tag, pageUrl, theme, ranked)
  }
  ranked.sort((lhs, rhs) => lhs.rank - rhs.rank || lhs.order - rhs.order)
  return [...new Set(ranked.map((candidate) => candidate.url))]
}

export const rankMcpIcons = (
  icons: ReadonlyArray<McpIcon>,
  theme: ToolIconTheme
): ReadonlyArray<McpIcon> =>
  icons
    .map((icon, order) => {
      const sizes = largestSize(icon.sizes?.join(" "))
      const size = sizes === Number.POSITIVE_INFINITY ? 64 : (sizes ?? 48)
      const declared = icon.theme === "dark" || icon.theme === "light" ? icon.theme : undefined
      return { icon, order, rank: themeRank(declared, theme) + Math.abs(size - 64) }
    })
    .toSorted((lhs, rhs) => lhs.rank - rhs.rank || lhs.order - rhs.order)
    .map(({ icon }) => icon)

const PRIVATE_SUFFIXES = [
  ".localhost",
  ".local",
  ".internal",
  ".intranet",
  ".corp",
  ".lan",
  ".home",
  ".arpa",
  ".test",
  ".example",
  ".invalid"
]

export const isPublicHost = (host: string): boolean => {
  const name = host.toLowerCase()
  if (!name.includes(".") || name.includes(":") || /^[\d.]+$/.test(name)) return false
  return !PRIVATE_SUFFIXES.some((suffix) => name.endsWith(suffix))
}

export const publicFaviconUrl = (host: string): string =>
  `https://icons.duckduckgo.com/ip3/${encodeURIComponent(host)}.ico`
