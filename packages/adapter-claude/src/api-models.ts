import type { ModelInfo } from "@anthropic-ai/claude-agent-sdk"

import { isRecord } from "./internal.js"

interface AnthropicModel {
  readonly id: string
  readonly displayName: string
  readonly line: string
  readonly createdAt: string
  readonly effortLevels: ReadonlyArray<EffortLevel>
}

export const claudeModelList = (
  cliModels: Promise<ModelInfo[]>,
  env: Readonly<Record<string, string>>,
  request: typeof fetch
): Promise<ModelInfo[]> => {
  const auth = authHeaders(env)
  if (auth === undefined) return cliModels

  return pickerModels(cliModels, fetchAnthropicModels(modelsUrl(env), auth, request))
}

type EffortLevel = NonNullable<ModelInfo["supportedEffortLevels"]>[number]

const ANTHROPIC_API_ORIGIN = "https://api.anthropic.com"
const MODELS_PATH = "/v1/models?limit=1000"
const ANTHROPIC_VERSION = "2023-06-01"
const OAUTH_BETA = "oauth-2025-04-20"
const MODELS_REQUEST_TIMEOUT_MS = 10_000
const LINE_ORDER: ReadonlyArray<string> = ["opus", "fable", "sonnet", "haiku"]
const EFFORT_LEVELS: ReadonlyArray<EffortLevel> = ["low", "medium", "high", "xhigh", "max"]

const pickerModels = async (
  cliModels: Promise<ModelInfo[]>,
  anthropicModels: Promise<ReadonlyArray<AnthropicModel>>
): Promise<ModelInfo[]> => {
  const [cli, anthropic] = await Promise.allSettled([cliModels, anthropicModels])
  const latest = latestPerLine(anthropic.status === "fulfilled" ? anthropic.value : [])
  if (latest.length === 0) return cliModels

  const known = cli.status === "fulfilled" ? cli.value : []
  return latest.map((model) => asModelInfo(model, known))
}

const fetchAnthropicModels = async (
  url: string,
  auth: Record<string, string>,
  request: typeof fetch
): Promise<ReadonlyArray<AnthropicModel>> => {
  const response = await request(url, {
    headers: { accept: "application/json", "anthropic-version": ANTHROPIC_VERSION, ...auth },
    signal: AbortSignal.timeout(MODELS_REQUEST_TIMEOUT_MS)
  })
  if (!response.ok) {
    await response.body?.cancel()
    return []
  }
  return anthropicModelsFrom(await response.json())
}

const authHeaders = (env: Readonly<Record<string, string>>): Record<string, string> | undefined => {
  const oauthToken = env.CLAUDE_CODE_OAUTH_TOKEN
  if (oauthToken) return { authorization: `Bearer ${oauthToken}`, "anthropic-beta": OAUTH_BETA }

  const apiKey = env.ANTHROPIC_API_KEY
  if (apiKey) return { "x-api-key": apiKey }
  return undefined
}

const modelsUrl = (env: Readonly<Record<string, string>>): string =>
  `${(env.ANTHROPIC_BASE_URL || ANTHROPIC_API_ORIGIN).replace(/\/+$/, "")}${MODELS_PATH}`

const anthropicModelsFrom = (body: unknown): ReadonlyArray<AnthropicModel> => {
  if (!isRecord(body) || !Array.isArray(body.data)) return []
  return body.data.flatMap(anthropicModelFrom)
}

const anthropicModelFrom = (entry: unknown): ReadonlyArray<AnthropicModel> => {
  if (!isActiveModel(entry)) return []
  return [
    {
      id: entry.id,
      displayName: entry.display_name,
      line: entry.line,
      createdAt: typeof entry.created_at === "string" ? entry.created_at : "",
      effortLevels: supportedEfforts(entry.capabilities)
    }
  ]
}

const isActiveModel = (
  entry: unknown
): entry is Record<string, unknown> & { id: string; display_name: string; line: string } =>
  isRecord(entry) &&
  typeof entry.id === "string" &&
  typeof entry.display_name === "string" &&
  typeof entry.line === "string" &&
  (entry.lifecycle === undefined || entry.lifecycle === "active")

const supportedEfforts = (capabilities: unknown): ReadonlyArray<EffortLevel> => {
  if (!isRecord(capabilities) || !isRecord(capabilities.effort)) return []
  const effort = capabilities.effort
  return EFFORT_LEVELS.filter(
    (level) => isRecord(effort[level]) && effort[level].supported === true
  )
}

const latestPerLine = (models: ReadonlyArray<AnthropicModel>): ReadonlyArray<AnthropicModel> => {
  const newest = new Map<string, AnthropicModel>()
  for (const model of models) {
    const current = newest.get(model.line)
    if (current === undefined || model.createdAt > current.createdAt) newest.set(model.line, model)
  }
  return [...newest.values()].toSorted(byLineOrder)
}

const byLineOrder = (left: AnthropicModel, right: AnthropicModel): number =>
  lineRank(left.line) - lineRank(right.line) || right.createdAt.localeCompare(left.createdAt)

const lineRank = (line: string): number => {
  const rank = LINE_ORDER.indexOf(line)
  return rank === -1 ? LINE_ORDER.length : rank
}

const asModelInfo = (model: AnthropicModel, cli: ReadonlyArray<ModelInfo>): ModelInfo => ({
  value: model.id,
  resolvedModel: model.id,
  displayName: model.displayName.replace(/^Claude /, ""),
  description: "",
  supportsEffort: model.effortLevels.length > 0,
  supportedEffortLevels: [...model.effortLevels],
  supportsFastMode: cli.some((entry) => offersFastMode(entry, model.id))
})

const offersFastMode = (entry: ModelInfo, id: string): boolean =>
  entry.resolvedModel === id && entry.supportsFastMode === true
