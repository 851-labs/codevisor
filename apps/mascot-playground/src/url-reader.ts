export class UrlReader {
  constructor(private readonly params: URLSearchParams) {}

  choice<Id extends string>(key: string, allowed: ReadonlyArray<Id>, fallback: Id): Id {
    const text = this.params.get(key)
    return allowed.find((id) => id === text) ?? fallback
  }

  number(key: string, fallback: number): number {
    const value = Number(this.params.get(key) ?? Number.NaN)
    return Number.isFinite(value) ? value : fallback
  }

  numberFrom(key: string, allowed: ReadonlyArray<number>, fallback: number): number {
    const value = this.number(key, fallback)
    return allowed.includes(value) ? value : fallback
  }

  flag(key: string, fallback: boolean): boolean {
    const text = this.params.get(key)
    if (text === null) return fallback
    return text === "1"
  }
}

export type Leaf = string | number | boolean

export function leaves(value: unknown, prefix = ""): ReadonlyArray<readonly [string, Leaf]> {
  if (!isRecord(value)) return []

  return Object.entries(value).flatMap(([key, child]) => {
    const path = prefix + key
    if (isLeaf(child)) return [[path, child] as const]
    return leaves(child, `${path}.`)
  })
}

export const leafText = (value: Leaf): string => {
  if (typeof value === "boolean") return value ? "1" : "0"
  return String(value)
}

const isRecord = (value: unknown): value is object => typeof value === "object" && value !== null

const isLeaf = (value: unknown): value is Leaf =>
  typeof value === "string" || typeof value === "number" || typeof value === "boolean"
