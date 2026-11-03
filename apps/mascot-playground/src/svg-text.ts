import type { RenderContext, Torso } from "@codevisor/bot-mascot"

export const torsoOf = (svg: string, ctx: RenderContext): Torso => ({
  d: /data-r="body" d="([^"]+)"/.exec(svg)?.[1] ?? "",
  shoulderY: ctx.body.shoulderY
})

export const bodyTransformOf = (svg: string): string =>
  /data-r="tf" transform="([^"]+)"/.exec(svg)?.[1] ?? ""

export const withOverlay = (svg: string, overlay: string): string =>
  overlay ? svg.replace(/<\/svg>$/, `${overlay}</svg>`) : svg

export const withPixelSize = (svg: string, pixels: number): string =>
  svg.replace(/^<svg /, `<svg width="${pixels}" height="${pixels}" `)
