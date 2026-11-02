import type { Point } from "../geometry/math.js"

export interface BodyZones {
  readonly dy: number
  readonly y0: number
  readonly neck: number
  readonly up?: number
}

export const officialBodyZones: BodyZones = { dy: 33.9, y0: 359 - 33.9, neck: 7 + 33.9, up: 3 }

export const originalBodyZones: BodyZones = { dy: 0, y0: 292, neck: 0 }

export interface Body {
  readonly zones: BodyZones | null
  readonly zoned: boolean
  readonly rise: number
  readonly shoulderY: number
  readonly clothesShoulderY: number
  readonly zoneMap: (p: Point) => Point
  readonly zoneY: (y: number) => number
  readonly waistMap: (p: Point) => Point
}

const ORIGINAL_SHOULDER_Y = 292
const STRETCH_TOP = 300
const STRETCH_BOTTOM = 340
const STRETCH_SPAN = STRETCH_BOTTOM - STRETCH_TOP

export const bodyOf = (requested: BodyZones | null | undefined): Body => {
  const zones = normalizeZones(requested)
  const dy = zones?.dy ?? 0
  const zoned = zones !== null && dy > 1e-3
  return {
    zones,
    zoned,
    rise: zoned ? dy : 0,
    shoulderY: zones ? zones.y0 - (zones.up || 0) : ORIGINAL_SHOULDER_Y,
    clothesShoulderY: zones ? zones.y0 : ORIGINAL_SHOULDER_Y,
    zoneMap: (p) => (zoned ? [p[0], stretchY(p[1], dy)] : p),
    zoneY: (y) => (zoned ? unstretchY(y, dy) : y),
    waistMap: (p) => (zones && zoned ? waistY(p, zones) : p)
  }
}

export const officialBody = bodyOf(officialBodyZones)

function normalizeZones(z: BodyZones | null | undefined): BodyZones | null {
  if (!z) return null
  const changed = z.dy > 1e-3 || Math.abs(z.y0 - ORIGINAL_SHOULDER_Y) > 1e-3 || z.neck > 1e-3
  return changed ? { ...z } : null
}

function stretchY(y: number, dy: number): number {
  if (y <= STRETCH_TOP) return y - dy
  if (y >= STRETCH_BOTTOM) return y
  return STRETCH_TOP - dy + ((y - STRETCH_TOP) * (STRETCH_SPAN + dy)) / STRETCH_SPAN
}

function unstretchY(y: number, dy: number): number {
  if (y <= STRETCH_TOP - dy) return y + dy
  if (y >= STRETCH_BOTTOM) return y
  return STRETCH_TOP + ((y - (STRETCH_TOP - dy)) * STRETCH_SPAN) / (STRETCH_SPAN + dy)
}

function waistY([x, y]: Point, zones: BodyZones): Point {
  const top = Math.min(zones.y0 + 11, 350)
  if (y < 311) return [x, top - (311 - y)]
  if (y <= 370) return [x, top + ((y - 311) * (376 - top)) / 59]
  return [x, y + 6]
}
