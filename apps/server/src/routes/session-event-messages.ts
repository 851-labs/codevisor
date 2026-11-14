import type { ExecTaskEvent, ExecutionJob, QuestionPayload, SessionSummary } from "@codevisor/api"

export interface SessionEventMessage {
  readonly text: string
}

export const REPORT_LIMIT = 4_000

const EVENT_OPENING = "<codevisor-event "

export const attribute = (value: string): string =>
  value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;")

export interface TurnEnd {
  readonly stopReason: string | undefined
  readonly finalText: string
  readonly usageLimitDetail?: string | undefined
}

export const turnEndedMessage = (
  target: Pick<SessionSummary, "id" | "title">,
  end: TurnEnd,
  subscriptionId?: string
): SessionEventMessage => ({
  text: eventBlock(
    `type="session.turn_ended" agentId="${attribute(target.id)}" title="${attribute(target.title)}"${stopAttributes(end)}${subscriptionAttribute(subscriptionId)}`,
    turnEndBody(end)
  )
})

export const userMessageMessage = (
  target: Pick<SessionSummary, "id" | "title">,
  text: string
): SessionEventMessage => ({
  text: eventBlock(
    `type="session.user_message" agentId="${attribute(target.id)}" title="${attribute(target.title)}"`,
    [
      "The user wrote to this agent directly. Its next reply answers them, not you:",
      bounded(text, "(no text)")
    ].join("\n\n")
  )
})

export const waitingForUserMessage = (
  target: Pick<SessionSummary, "id" | "title">,
  kind: string,
  question: QuestionPayload | undefined,
  subscriptionId?: string
): SessionEventMessage => ({
  text: eventBlock(
    `type="session.waiting_for_user" agentId="${attribute(target.id)}" title="${attribute(target.title)}" kind="${attribute(kind)}"${subscriptionAttribute(subscriptionId)}`,
    waitingBody(kind, question)
  )
})

export const erroredMessage = (
  target: Pick<SessionSummary, "id" | "title">,
  message: string,
  subscriptionId?: string
): SessionEventMessage => ({
  text: eventBlock(
    `type="session.errored" agentId="${attribute(target.id)}" title="${attribute(target.title)}"${subscriptionAttribute(subscriptionId)}`,
    bounded(message, "(no error message)")
  )
})

export const jobFinishedMessage = (
  job: ExecutionJob,
  subscriptionId?: string
): SessionEventMessage => ({
  text: eventBlock(
    `type="execution.job_finished" jobId="${attribute(job.jobId)}" agentId="${attribute(job.sessionId)}" state="${job.state}" description="${attribute(job.description)}"${subscriptionAttribute(subscriptionId)}`,
    [bounded(jobOutcome(job), "(no result)"), `Full output: ${job.outputPath}`].join("\n")
  )
})

export const execTaskFinishedMessage = (
  finished: ExecTaskEvent,
  subscriptionId?: string
): SessionEventMessage => {
  const { task } = finished
  const exitCode =
    task.exitCode === undefined || task.exitCode === null ? "" : ` exitCode="${task.exitCode}"`
  return {
    text: eventBlock(
      `type="exec.task_finished" taskId="${attribute(task.taskId)}" agentId="${attribute(finished.sessionId)}" state="${task.state}"${exitCode} description="${attribute(task.description)}"${subscriptionAttribute(subscriptionId)}`,
      [boundedTail(finished.outputTail, "(no output)"), `Full output: ${task.outputPath}`].join(
        "\n"
      )
    )
  }
}

export const fromMachine = (
  message: SessionEventMessage,
  machine: { readonly id: string; readonly name: string }
): SessionEventMessage => ({
  text: message.text.replace(
    EVENT_OPENING,
    `${EVENT_OPENING}machine="${attribute(machine.name)}" machineId="${attribute(machine.id)}" `
  )
})

const eventBlock = (attributes: string, body: string): string =>
  [`${EVENT_OPENING}${attributes}>`, body, "</codevisor-event>"].join("\n")

const subscriptionAttribute = (subscriptionId: string | undefined): string =>
  subscriptionId === undefined ? "" : ` subscriptionId="${attribute(subscriptionId)}"`

const stopAttributes = (end: TurnEnd): string => {
  const reason = end.stopReason === undefined ? "" : ` stopReason="${attribute(end.stopReason)}"`
  const kind = end.usageLimitDetail === undefined ? "" : ' stopKind="usageLimit"'
  return `${reason}${kind}`
}

const turnEndBody = (end: TurnEnd): string => {
  if (end.usageLimitDetail === undefined) return orPlaceholder(end.finalText, "(no final message)")

  const paused = `Paused at its usage limit: ${end.usageLimitDetail}\n${resumesOnItsOwn}`
  return [end.finalText, paused].filter((part) => part.length > 0).join("\n\n")
}

const resumesOnItsOwn = "It continues on its own once usage is available."

const orPlaceholder = (text: string, empty: string): string => (text.length === 0 ? empty : text)

const boundedTail = (text: string, empty: string): string => {
  if (text.length <= REPORT_LIMIT) return orPlaceholder(text, empty)
  return `…(earlier output cut)\n${text.slice(-REPORT_LIMIT)}`
}

const bounded = (text: string, empty: string): string => {
  if (text.length <= REPORT_LIMIT) return orPlaceholder(text, empty)
  return `${text.slice(0, REPORT_LIMIT)}\n…(truncated)`
}

const waitingBody = (kind: string, question: QuestionPayload | undefined): string => {
  if (question === undefined) return `The agent is waiting for ${kindLabel(kind)}.`
  const asked = JSON.stringify({
    questionId: question.questionId,
    ...(question.message === undefined ? {} : { message: question.message }),
    questions: question.questions
  })
  return `${bounded(asked, "")}\n${answerHint}`
}

const answerHint =
  'Answer it with agents.answer({ agentId, machine, questionId, outcome: "answered", answers }), where machine is this event\'s machineId when it has one and answers maps each question\'s id to { answers: ["<chosen option>"] }, or send guidance with agents.message({ agentId, machine, text }).'

const kindLabel = (kind: string): string =>
  kind === "planApproval" ? "plan approval" : "an answer"

const jobOutcome = (job: ExecutionJob): string => {
  if (job.state === "completed") return `Result: ${safeJson(job.result)}`
  return `Error: ${job.error ?? job.state}`
}

const safeJson = (value: unknown): string => {
  try {
    return JSON.stringify(value) ?? "undefined"
  } catch {
    return String(value)
  }
}
