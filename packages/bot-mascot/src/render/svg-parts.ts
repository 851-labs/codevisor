const capture = (svg: string, pattern: RegExp): string => {
  const m = pattern.exec(svg)
  if (!m?.[1]) throw new Error(`bot mascot SVG is missing ${pattern.source}`)
  return m[1]
}

export const svgBody = (svg: string): string => capture(svg, /data-r="body" d="([^"]+)"/)

export const svgTransform = (svg: string): string => capture(svg, /data-r="tf" transform="([^"]+)"/)

export const svgGradientId = (svg: string): string => capture(svg, /<linearGradient id="([^"]+)"/)

export const svgUid = (svg: string): string => capture(svg, /<linearGradient id="([^"]+)g"/)

export const svgSleeve = (svg: string): string | undefined => /data-sleeve="([^"]+)"/.exec(svg)?.[1]

export const withSize = (svg: string, size: number | undefined): string =>
  size ? svg.replace("<svg ", `<svg width="${size}" height="${size}" `) : svg

export const appendBeforeClose = (svg: string, extra: string): string =>
  svg.replace(/<\/svg>$/, `${extra}</svg>`)
