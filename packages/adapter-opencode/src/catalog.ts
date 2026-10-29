import { relative } from "node:path"

import { COMPACT_COMMAND, sessionSkills } from "@codevisor/agent-runtime"
import type {
  CanonicalModeId,
  SessionConfigOption,
  SessionModeState,
  SessionSkill,
  SessionSkills
} from "@codevisor/api"

import { record, type JsonRecord } from "./internal.js"
import type { OpenCodeServer } from "./server.js"

export interface ModelRef {
  readonly providerID: string
  readonly id: string
  readonly variant?: string
}

export interface CatalogModel extends ModelRef {
  readonly name: string
  readonly variants: ReadonlyArray<string>
  readonly context?: number
}

export interface CatalogMode {
  readonly id: string
  readonly name: string
  readonly description?: string
}

export interface Catalog {
  readonly models: ReadonlyArray<CatalogModel>
  readonly defaultModel: ModelRef
  readonly modes: ReadonlyArray<CatalogMode>
  readonly defaultModeID: string
  readonly commands: ReadonlyArray<string>
  readonly skills: SessionSkills
}

export interface Selection {
  readonly model?: ModelRef
  readonly agent?: string
}

export type SelectionChange = { readonly model: ModelRef } | { readonly agent: string }

const DEFAULT_VARIANT = "default"
const CATALOG_ATTEMPTS = 200
const CATALOG_POLL_MS = 25

const list = (value: unknown): ReadonlyArray<JsonRecord> => {
  const data = record(value)?.data
  if (!Array.isArray(data)) return []
  return data.flatMap((entry: unknown): Array<JsonRecord> => {
    const item = record(entry)
    return item === undefined ? [] : [item]
  })
}

const optional = (value: unknown): string | undefined =>
  typeof value === "string" && value !== "" ? value : undefined

const decodeModel = (value: JsonRecord): CatalogModel | undefined => {
  if (typeof value.id !== "string" || typeof value.providerID !== "string") return undefined
  if (value.enabled === false) return undefined
  const context = record(value.limit)?.context
  return {
    providerID: value.providerID,
    id: value.id,
    name: optional(value.name) ?? value.id,
    variants: (Array.isArray(value.variants) ? value.variants : []).flatMap((variant: unknown) => {
      const id = record(variant)?.id
      return typeof id === "string" ? [id] : []
    }),
    ...(typeof context === "number" && context > 0 ? { context } : {})
  }
}

export const findModel = (
  models: ReadonlyArray<CatalogModel>,
  ref: ModelRef | undefined
): CatalogModel | undefined =>
  ref === undefined
    ? undefined
    : models.find((model) => model.providerID === ref.providerID && model.id === ref.id)

export const decodeModelRef = (value: unknown): ModelRef | undefined => {
  const ref = record(value)
  if (typeof ref?.providerID !== "string" || typeof ref.id !== "string") return undefined
  const variant = optional(ref.variant)
  return { providerID: ref.providerID, id: ref.id, ...(variant === undefined ? {} : { variant }) }
}

const skillSource = (path: string | undefined, cwd: string): SessionSkill["source"] => {
  if (path === undefined) return undefined
  if (path.startsWith("/builtin/")) return "builtin"
  const inside = relative(cwd, path)
  return inside.startsWith("..") || inside.startsWith("/") ? "user" : "project"
}

const decodeSkills = (entries: ReadonlyArray<JsonRecord>, cwd: string): SessionSkills =>
  sessionSkills(
    entries.flatMap((entry): Array<SessionSkill> => {
      if (typeof entry.id !== "string") return []
      const description = optional(entry.description)
      const source = skillSource(optional(entry.path), cwd)
      return [
        {
          name: entry.id,
          invocation: `/${entry.id}`,
          ...(description === undefined ? {} : { description }),
          ...(source === undefined ? {} : { source })
        }
      ]
    }),
    "/",
    [COMPACT_COMMAND]
  )

const readCatalog = async (server: OpenCodeServer, cwd: string): Promise<Catalog | undefined> => {
  const get = (path: string) => server.request(path, { location: cwd })
  const [models, preferred, agents, commands, skills] = await Promise.all([
    get("/api/model"),
    get("/api/model/default"),
    get("/api/agent"),
    get("/api/command"),
    get("/api/skill").catch(() => ({ data: [] }))
  ])
  const enabled = list(models).flatMap((entry) => decodeModel(entry) ?? [])
  const model = findModel(enabled, decodeModelRef(record(preferred)?.data)) ?? enabled[0]
  const modes = list(agents).flatMap((agent): Array<CatalogMode> => {
    if (typeof agent.id !== "string" || agent.mode === "subagent" || agent.hidden === true)
      return []
    const description = optional(agent.description)
    return [
      {
        id: agent.id,
        name: optional(agent.name) ?? agent.id,
        ...(description === undefined ? {} : { description })
      }
    ]
  })
  if (model === undefined || modes[0] === undefined) return undefined
  return {
    models: enabled,
    defaultModel: {
      providerID: model.providerID,
      id: model.id,
      ...(model.variants.includes(DEFAULT_VARIANT) ? { variant: DEFAULT_VARIANT } : {})
    },
    modes,
    defaultModeID: modes[0].id,
    commands: list(commands).flatMap((command) =>
      typeof command.name === "string" ? [command.name] : []
    ),
    skills: decodeSkills(list(skills), cwd)
  }
}

const delay = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms).unref())

export const loadCatalog = async (
  server: OpenCodeServer,
  cwd: string,
  wait: (ms: number) => Promise<void> = delay
): Promise<Catalog> => {
  for (let attempt = 1; ; attempt += 1) {
    const plugins = list(await server.request("/api/plugin", { location: cwd }))
    let catalog: Catalog | undefined
    if (plugins.length !== 0) catalog = await readCatalog(server, cwd)
    if (catalog !== undefined) return catalog
    if (attempt >= CATALOG_ATTEMPTS) {
      const late = await readCatalog(server, cwd)
      if (late !== undefined) return late
      throw new Error("OpenCode has no models or agents available for this project.")
    }
    await wait(CATALOG_POLL_MS)
  }
}

export const currentModel = (catalog: Catalog, selection: Selection): ModelRef =>
  selection.model ?? catalog.defaultModel

const advertised = (model: ModelRef) => `${model.providerID}/${model.id}`

const variantName = (variant: string) =>
  variant
    .split(/[_-]/)
    .map((part) => (part === "" ? part : part.charAt(0).toUpperCase() + part.slice(1)))
    .join(" ")

const selectedVariant = (variant: string | undefined, variants: ReadonlyArray<string>) => {
  if (variant === undefined || variant === DEFAULT_VARIANT) return DEFAULT_VARIANT
  if (variants.includes(variant)) return variant
  if (variants.includes(DEFAULT_VARIANT)) return DEFAULT_VARIANT
  return variants[0] ?? DEFAULT_VARIANT
}

const compareProviderIds = (a: ModelRef, b: ModelRef): number => {
  if (a.providerID < b.providerID) return -1
  if (a.providerID > b.providerID) return 1
  return 0
}

export const configOptions = (
  catalog: Catalog,
  selection: Selection
): ReadonlyArray<SessionConfigOption> => {
  const model = currentModel(catalog, selection)
  const variants = findModel(catalog.models, model)?.variants ?? []
  return [
    {
      id: "model",
      name: "Model",
      category: "model",
      currentValue: advertised(model),
      options: catalog.models
        .toSorted((a, b) => compareProviderIds(a, b) || a.name.localeCompare(b.name))
        .map((item) => ({ value: advertised(item), name: `${item.providerID}/${item.name}` }))
    },
    ...(variants.length === 0
      ? []
      : [
          {
            id: "effort",
            name: "Effort",
            description: "Available effort levels for this model",
            category: "thought_level",
            currentValue: selectedVariant(model.variant, variants),
            options: [...new Set([...variants, DEFAULT_VARIANT])].map((variant) => ({
              value: variant,
              name: variantName(variant)
            }))
          }
        ])
  ]
}

const CANONICAL_MODES: ReadonlyArray<readonly [CanonicalModeId, RegExp]> = [
  ["plan", /^plan/i],
  ["readOnly", /read[-_ ]?only/i],
  ["autoEdit", /accept[-_ ]?edits|auto[-_ ]?edit/i],
  ["fullAccess", /bypass|full[-_ ]?access|yolo/i],
  ["ask", /^(default|ask|normal)$/i]
]

const canonicalMode = (mode: CatalogMode): CanonicalModeId | undefined =>
  CANONICAL_MODES.find(([, pattern]) => pattern.test(mode.id) || pattern.test(mode.name))?.[0]

export const sessionModes = (catalog: Catalog, selection: Selection): SessionModeState => ({
  currentModeId: selection.agent ?? catalog.defaultModeID,
  availableModes: catalog.modes.map((mode) => {
    const canonicalId = canonicalMode(mode)
    return {
      id: mode.id,
      name: mode.name,
      ...(mode.description === undefined ? {} : { description: mode.description }),
      ...(canonicalId === undefined ? {} : { canonicalId })
    }
  })
})

const parseModel = (value: string, models: ReadonlyArray<CatalogModel>): ModelRef | undefined => {
  const exact = models.find((model) => advertised(model) === value)
  if (exact !== undefined) return { providerID: exact.providerID, id: exact.id }
  const separator = value.lastIndexOf("/")
  const variant = value.slice(separator + 1)
  const base = models.find(
    (model) => advertised(model) === value.slice(0, separator) && model.variants.includes(variant)
  )
  return base === undefined ? undefined : { providerID: base.providerID, id: base.id, variant }
}

export const resolveChange = (
  catalog: Catalog,
  selection: Selection,
  configId: string,
  value: string
): SelectionChange => {
  const current = currentModel(catalog, selection)
  if (configId === "model") {
    const selected = parseModel(value, catalog.models)
    if (selected === undefined) throw new Error(`Unknown OpenCode model: ${value}`)
    const model = findModel(catalog.models, selected)!
    const keep =
      selected.variant === undefined &&
      current.providerID === model.providerID &&
      current.id === model.id &&
      current.variant !== undefined &&
      (current.variant === DEFAULT_VARIANT || model.variants.includes(current.variant))
    const variant = selected.variant ?? (keep ? current.variant : undefined)
    return {
      model: {
        providerID: model.providerID,
        id: model.id,
        ...(variant === undefined ? {} : { variant })
      }
    }
  }
  if (configId === "effort") {
    const model = findModel(catalog.models, current)
    if (model === undefined || (value !== DEFAULT_VARIANT && !model.variants.includes(value)))
      throw new Error(`Unknown OpenCode effort: ${value}`)
    return { model: { providerID: current.providerID, id: current.id, variant: value } }
  }
  if (configId === "mode") {
    const mode = catalog.modes.find((candidate) => candidate.id === value)
    if (mode === undefined) throw new Error(`Unknown OpenCode mode: ${value}`)
    return { agent: mode.id }
  }
  throw new Error(`Unknown OpenCode config option: ${configId}`)
}

export const permissionsGated = (catalog: Catalog, selection: Selection): boolean => {
  const id = selection.agent ?? catalog.defaultModeID
  const canonical = canonicalMode(catalog.modes.find((mode) => mode.id === id) ?? { id, name: id })
  return canonical === "plan" || canonical === "readOnly"
}
