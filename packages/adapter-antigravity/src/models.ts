import type { SessionConfigOption } from "@codevisor/api"

/// agy's model catalog as Codevisor's Model and Reasoning pickers. `agy
/// models` lists one line per variant (`gemini-4-argon-high  Gemini 4 Argon
/// (High)`); the variants of one model share a picker entry, and the tier is
/// the reasoning level.

export const MODEL_OPTION_ID = "model"
export const EFFORT_OPTION_ID = "thought_level"

export interface AgyModelVariant {
  /// What `--model` takes.
  readonly slug: string
  readonly tier: string | undefined
  readonly label: string | undefined
}

export interface AgyModel {
  readonly id: string
  readonly name: string
  readonly variants: ReadonlyArray<AgyModelVariant>
}

// agy separates the columns with a tab (or, in older builds, runs of spaces).
const LINE = /^([A-Za-z0-9][\w.-]*)(?:\t|\s{2,})\s*(\S.*?)\s*$/
const TIERED = /^(.*\S)\s+\(([^()]+)\)$/

export const parseModels = (output: string): Array<AgyModel> => {
  const models: Array<{ id: string; name: string; variants: Array<AgyModelVariant> }> = []
  for (const line of output.split("\n")) {
    const listed = LINE.exec(line.trim())
    if (listed === null) continue
    const [, slug, display] = listed as unknown as [string, string, string]
    const tiered = TIERED.exec(display)
    const label = tiered?.[2]
    const tier = label?.toLowerCase().replace(/\s+/g, "-")
    const id =
      tier !== undefined && slug.toLowerCase().endsWith(`-${tier}`)
        ? slug.slice(0, -(tier.length + 1))
        : slug
    const name = tiered?.[1] ?? display
    const existing = models.find((model) => model.id === id)
    const variant = { slug, tier, label }
    if (existing === undefined) models.push({ id, name, variants: [variant] })
    else existing.variants.push(variant)
  }
  return models
}

/// The tier a model runs at when nobody chose one.
export const defaultTier = (model: AgyModel): string | undefined => {
  const tiers = model.variants.map((variant) => variant.tier)
  return tiers.includes("medium") ? "medium" : tiers[0]
}

/// The model and tier a chat runs, falling back to agy's first listing (its
/// recommended model) and the model's default tier.
export const resolveSelection = (
  models: ReadonlyArray<AgyModel>,
  selection: { readonly modelId?: string | undefined; readonly tier?: string | undefined }
): { readonly model: AgyModel; readonly variant: AgyModelVariant } | undefined => {
  const model = models.find((entry) => entry.id === selection.modelId) ?? models[0]
  if (model === undefined) return undefined
  const variant =
    model.variants.find((entry) => entry.tier === selection.tier) ??
    model.variants.find((entry) => entry.tier === defaultTier(model))!
  return { model, variant }
}

export const configOptions = (
  models: ReadonlyArray<AgyModel>,
  selection: { readonly modelId?: string | undefined; readonly tier?: string | undefined }
): Array<SessionConfigOption> => {
  const resolved = resolveSelection(models, selection)
  if (resolved === undefined) return []
  const options: Array<SessionConfigOption> = [
    {
      id: MODEL_OPTION_ID,
      name: "Model",
      category: "model",
      currentValue: resolved.model.id,
      options: models.map((model) => ({ value: model.id, name: model.name }))
    }
  ]
  const tiers = resolved.model.variants.filter((variant) => variant.tier !== undefined)
  if (tiers.length > 1)
    options.push({
      id: EFFORT_OPTION_ID,
      name: "Reasoning",
      category: "thought_level",
      currentValue: resolved.variant.tier!,
      options: tiers.map((variant) => ({ value: variant.tier!, name: variant.label! }))
    })
  return options
}
