import {
  list,
  number,
  record,
  string,
  type ApprovalChoice,
  type ApprovalRequest,
  type ModelCatalogEntry,
  type MuseItem,
  type MuseSession,
  type PatchSummary,
  type UserInputQuestion,
  type UserInputRequest
} from "./protocol.js"

const nullable = (value: unknown): string | null => string(value) ?? null

const strings = (value: unknown): ReadonlyArray<string> =>
  list(value).filter((entry): entry is string => typeof entry === "string")

const patchSummary = (value: unknown): PatchSummary | undefined => {
  const summary = record(value)
  const added = number(summary.added)
  const removed = number(summary.removed)
  return added === undefined || removed === undefined
    ? undefined
    : { files: number(summary.files) ?? 0, added, removed }
}

export const museItem = (value: unknown): MuseItem | undefined => {
  const item = record(value)
  const itemId = string(item.itemId)
  if (itemId === undefined) return undefined
  const result = record(item.result)
  return {
    itemId,
    kind: string(item.kind) ?? "",
    status: string(item.status) ?? "",
    revision: number(item.revision) ?? 0,
    turnId: item.turnId === null ? null : string(item.turnId),
    text: string(item.text),
    summary: strings(item.summary),
    tool: string(item.tool),
    args: string(item.args),
    visibleOutput: string(item.visibleOutput),
    patchSummary: patchSummary(item.patchSummary),
    failureReason: string(item.failureReason),
    childSessionId: string(item.childSessionId),
    controlStatus: string(item.controlStatus),
    objective: string(item.objective),
    role: string(item.role),
    agentPath: string(item.agentPath),
    subagentId: string(item.subagentId),
    result: { summary: string(result.summary), text: string(result.text) },
    selector: string(item.selector),
    query: string(item.query),
    url: string(item.url)
  }
}

export const museSession = (value: unknown): MuseSession | undefined => {
  const session = record(value)
  const sessionId = string(session.sessionId)
  if (sessionId === undefined) return undefined
  return {
    sessionId,
    workspaceRoot: nullable(session.workspaceRoot),
    modelId: nullable(session.modelId),
    providerId: nullable(session.providerId),
    name: string(session.name),
    title: string(session.title),
    firstUserPrompt: string(session.firstUserPrompt),
    updatedAt: string(session.updatedAt) ?? "",
    kind: string(session.kind)
  }
}

export const museSessions = (value: unknown): Array<MuseSession> =>
  list(value).flatMap((entry) => museSession(entry) ?? [])

export const requireSession = (response: unknown): MuseSession => {
  const session = museSession(record(response).session)
  if (session === undefined) throw new Error("Muse Code didn't return a session.")
  return session
}

const tiers = (value: unknown): ReadonlyArray<{ readonly tier: string }> =>
  list(value).flatMap((entry) => {
    const tier = string(record(entry).tier)
    return tier === undefined ? [] : [{ tier }]
  })

export const modelCatalog = (value: unknown): Array<ModelCatalogEntry> =>
  list(value).flatMap((entry) => {
    const model = record(entry)
    const modelId = string(model.modelId)
    if (modelId === undefined) return []
    return [
      {
        modelId,
        displayLabel: string(model.displayLabel) ?? modelId,
        providerId: string(model.providerId) ?? "",
        profileId: nullable(model.profileId),
        contextLimit: number(model.contextLimit) ?? null,
        isActive: model.isActive === true,
        isDefault: model.isDefault === true,
        defaultReasoningEffort: string(model.defaultReasoningEffort),
        variants: list(model.variants),
        reasoningEffortVariants: tiers(model.reasoningEffortVariants)
      }
    ]
  })

const choices = (value: unknown): ReadonlyArray<ApprovalChoice> =>
  list(value).flatMap((entry) => {
    const choice = record(entry)
    const choiceId = string(choice.choiceId)
    if (choiceId === undefined) return []
    return [
      {
        choiceId,
        label: string(choice.label) ?? choiceId,
        decision: string(choice.decision) ?? ""
      }
    ]
  })

export const approvalRequest = (value: unknown): ApprovalRequest | undefined => {
  const request = record(value)
  const approvalId = string(request.approvalId)
  if (approvalId === undefined) return undefined
  const subject = record(request.subject)
  return {
    approvalId,
    sessionId: string(request.sessionId) ?? "",
    toolName: string(request.toolName) ?? "tool",
    toolCallId: string(request.toolCallId) ?? "",
    rawArgs: string(request.rawArgs) ?? "",
    availableChoices: choices(request.availableChoices),
    currentRequirementId: record(request.currentRequirementId),
    subject: {
      kind: string(subject.kind) ?? "",
      command: string(subject.command),
      path: string(subject.path)
    }
  }
}

const questions = (value: unknown): ReadonlyArray<UserInputQuestion> =>
  list(value).flatMap((entry) => {
    const question = record(entry)
    const id = string(question.id)
    if (id === undefined) return []
    return [
      {
        id,
        header: string(question.header) ?? "",
        question: string(question.question) ?? "",
        options: list(question.options).flatMap((candidate) => {
          const option = record(candidate)
          const label = string(option.label)
          return label === undefined ? [] : [{ label, description: string(option.description) }]
        }),
        selection: { mode: string(record(question.selection).mode) ?? "single" }
      }
    ]
  })

export const userInputRequest = (value: unknown): UserInputRequest | undefined => {
  const request = record(value)
  const userInputId = string(request.userInputId)
  if (userInputId === undefined) return undefined
  return {
    userInputId,
    sessionId: string(request.sessionId) ?? "",
    questions: questions(request.questions),
    autoResolutionMs: number(request.autoResolutionMs)
  }
}
