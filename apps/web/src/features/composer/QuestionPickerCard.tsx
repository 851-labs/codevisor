import type { QuestionAnswerEntry } from "@herdman/api"
import {
  ArrowLeftIcon,
  ArrowRightIcon,
  ArrowUpIcon,
  CheckIcon,
  CircleIcon,
  XIcon
} from "lucide-react"
import { type KeyboardEvent, useEffect, useMemo, useRef, useState } from "react"

import { cn } from "../../lib/cn"
import type { QuestionRequestInfo, QuestionSpecInfo } from "../../lib/session-events"

const OTHER_TOKEN = "__other__"

export function QuestionPickerCard({
  request,
  isSubmitting = false,
  initialSelections,
  onAnswer,
  onCancel
}: {
  request: QuestionRequestInfo
  isSubmitting?: boolean
  initialSelections?: Record<string, readonly string[]>
  onAnswer: (answers: Record<string, QuestionAnswerEntry>) => void
  onCancel: () => void
}) {
  const [questionIndex, setQuestionIndex] = useState(0)
  const [selections, setSelections] = useState<Record<string, Set<string>>>(() =>
    selectionsFromInitial(initialSelections)
  )
  const [notes, setNotes] = useState<Record<string, string>>({})
  const [highlighted, setHighlighted] = useState(0)
  const rootRef = useRef<HTMLDivElement>(null)
  const noteRef = useRef<HTMLTextAreaElement>(null)

  const question = request.questions[questionIndex]
  const isLastQuestion = questionIndex >= request.questions.length - 1
  const isSubmittable = useMemo(
    () => areQuestionAnswersSubmittable(request.questions, selections, notes),
    [notes, request.questions, selections]
  )

  useEffect(() => {
    setQuestionIndex(0)
    setSelections(selectionsFromInitial(initialSelections))
    setNotes({})
    setHighlighted(0)
    rootRef.current?.focus()
  }, [initialSelections, request.questionId])

  useEffect(() => {
    const textarea = noteRef.current
    if (textarea == null) return
    textarea.style.height = "auto"
    textarea.style.height = `${Math.min(textarea.scrollHeight, 120)}px`
  }, [notes, question?.id])

  if (question == null) return null

  const selected = selections[question.id] ?? new Set()
  const rowCount = question.options.length + (question.allowsOther ? 1 : 0)
  const isOtherSelected = selected.has(OTHER_TOKEN)

  const activate = (target: QuestionSpecInfo, index: number) => {
    const token = index >= target.options.length ? OTHER_TOKEN : target.options[index]?.label
    if (token == null) return
    setSelections((current) => {
      const next = new Set(current[target.id] ?? [])
      if (target.multiSelect === true) {
        if (next.has(token)) next.delete(token)
        else next.add(token)
      } else {
        if (next.has(token)) next.clear()
        else {
          next.clear()
          next.add(token)
        }
      }
      return { ...current, [target.id]: next }
    })
  }

  const selectHighlighted = (target: QuestionSpecInfo, index: number) => {
    const nextSelections = selectionsWithHighlightedSingleSelect(selections, target, index)
    setSelections(nextSelections)
    return nextSelections
  }

  const moveQuestion = (delta: number) => {
    const next = questionIndex + delta
    if (!request.questions[next]) return
    setQuestionIndex(next)
    setHighlighted(0)
    rootRef.current?.focus()
  }

  const buildAnswers = (
    sourceSelections: Record<string, Set<string>> = selections
  ): Record<string, QuestionAnswerEntry> =>
    buildQuestionAnswers(request.questions, sourceSelections, notes)

  const submit = (sourceSelections: Record<string, Set<string>> = selections) => {
    if (
      !areQuestionAnswersSubmittable(request.questions, sourceSelections, notes) ||
      isSubmitting
    ) {
      return
    }
    onAnswer(buildAnswers(sourceSelections))
  }

  const advanceOrSubmit = (sourceSelections: Record<string, Set<string>> = selections) => {
    if (isLastQuestion) submit(sourceSelections)
    else moveQuestion(1)
  }

  const handleKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (document.activeElement === noteRef.current) return
    switch (event.key) {
      case "ArrowUp":
        event.preventDefault()
        setHighlighted((index) => Math.max(0, index - 1))
        return
      case "ArrowDown":
        event.preventDefault()
        setHighlighted((index) => Math.min(rowCount - 1, index + 1))
        return
      case "ArrowLeft":
        event.preventDefault()
        moveQuestion(-1)
        return
      case "ArrowRight":
        event.preventDefault()
        moveQuestion(1)
        return
      case " ":
        event.preventDefault()
        activate(question, highlighted)
        return
      case "Enter": {
        event.preventDefault()
        const nextSelections =
          question.multiSelect === true ? selections : selectHighlighted(question, highlighted)
        advanceOrSubmit(nextSelections)
        return
      }
      case "Escape":
        event.preventDefault()
        onCancel()
        return
      default: {
        const digit = Number.parseInt(event.key, 10)
        if (Number.isInteger(digit) && digit >= 1 && digit <= rowCount) {
          event.preventDefault()
          setHighlighted(digit - 1)
          activate(question, digit - 1)
        }
      }
    }
  }

  return (
    <div
      ref={rootRef}
      tabIndex={0}
      onKeyDown={handleKeyDown}
      className="border-primary/15 bg-composer flex flex-col gap-2.5 rounded-2xl border p-3 outline-none"
      aria-label="Agent question"
    >
      {request.message != null && request.message !== "" && (
        <p className="text-muted-foreground text-sm">{request.message}</p>
      )}
      <div className="flex items-start gap-2">
        <div className="min-w-0 flex-1">
          <h2 className="text-sm font-medium">{question.question}</h2>
        </div>
        <button
          type="button"
          aria-label="Dismiss without answering"
          title="Dismiss without answering (Esc)"
          onClick={onCancel}
          className="text-muted-foreground hover:text-foreground flex size-5 cursor-default items-center justify-center rounded outline-none"
        >
          <XIcon className="size-3" />
        </button>
      </div>

      <div className="flex flex-col gap-0.5">
        {question.options.map((option, index) => (
          <OptionRow
            key={option.id ?? option.label}
            label={option.label}
            description={option.description}
            index={index}
            isHighlighted={index === highlighted}
            isSelected={selected.has(option.label)}
            onActivate={() => {
              setHighlighted(index)
              activate(question, index)
            }}
          />
        ))}
        {question.allowsOther && (
          <OptionRow
            label="Other"
            description="Answer in your own words below."
            index={question.options.length}
            isHighlighted={question.options.length === highlighted}
            isSelected={isOtherSelected}
            onActivate={() => {
              setHighlighted(question.options.length)
              activate(question, question.options.length)
            }}
          />
        )}
      </div>

      <div
        className={cn(
          "bg-background/55 rounded-lg border px-2.5 py-1",
          isOtherSelected ? "border-primary/35" : "border-border"
        )}
      >
        <textarea
          ref={noteRef}
          rows={1}
          value={notes[question.id] ?? ""}
          placeholder={isOtherSelected ? "Type your answer (required)" : "Add a note (optional)"}
          onChange={(event) =>
            setNotes((current) => ({ ...current, [question.id]: event.target.value }))
          }
          onKeyDown={(event) => {
            if (event.key === "Escape") {
              event.preventDefault()
              rootRef.current?.focus()
            }
            if (event.key === "Enter" && !event.shiftKey) {
              event.preventDefault()
              advanceOrSubmit()
            }
          }}
          className="placeholder:text-muted-foreground/70 max-h-[120px] w-full resize-none bg-transparent text-sm outline-none"
        />
      </div>

      <div className="flex items-center gap-2">
        <span className="text-muted-foreground text-[11px]">
          {question.multiSelect === true
            ? "Space toggles · Return continues · Esc dismisses"
            : "↑↓ and 1-9 select · Return continues · Esc dismisses"}
        </span>
        <span className="flex-1" />
        {questionIndex > 0 && (
          <NavButton label="Previous question" onClick={() => moveQuestion(-1)}>
            <ArrowLeftIcon className="size-3.5" />
          </NavButton>
        )}
        {!isLastQuestion ? (
          <NavButton label="Next question" onClick={() => moveQuestion(1)}>
            <ArrowRightIcon className="size-3.5" />
          </NavButton>
        ) : (
          <button
            type="button"
            aria-label="Submit answers"
            title={isSubmittable ? "Submit answers (↩)" : '"Other" needs an answer below'}
            disabled={!isSubmittable || isSubmitting}
            onClick={() => submit()}
            className={cn(
              "flex size-7 cursor-default items-center justify-center rounded-full outline-none",
              isSubmittable && !isSubmitting
                ? "bg-[color-mix(in_srgb,var(--foreground)_82%,transparent)] text-primary-foreground"
                : "bg-[color-mix(in_srgb,var(--foreground)_16%,transparent)] text-muted-foreground/75"
            )}
          >
            <ArrowUpIcon className="size-3.5" strokeWidth={3} />
          </button>
        )}
      </div>
    </div>
  )
}

export function selectionsWithHighlightedSingleSelect(
  selections: Record<string, Set<string>>,
  target: QuestionSpecInfo,
  index: number
): Record<string, Set<string>> {
  const token = index >= target.options.length ? OTHER_TOKEN : target.options[index]?.label
  if (token == null) return selections
  return { ...selections, [target.id]: new Set([token]) }
}

export function buildQuestionAnswers(
  questions: readonly QuestionSpecInfo[],
  selections: Record<string, Set<string>>,
  notes: Record<string, string>
): Record<string, QuestionAnswerEntry> {
  const answers: Record<string, QuestionAnswerEntry> = {}
  for (const entry of questions) {
    const selectedLabels = entry.options
      .map((option) => option.label)
      .filter((label) => selections[entry.id]?.has(label) === true)
    const note = (notes[entry.id] ?? "").trim()
    if (selectedLabels.length > 0 || note !== "") {
      answers[entry.id] = {
        answers: selectedLabels,
        note: note === "" ? undefined : note
      }
    }
  }
  return answers
}

export function areQuestionAnswersSubmittable(
  questions: readonly QuestionSpecInfo[],
  selections: Record<string, Set<string>>,
  notes: Record<string, string>
): boolean {
  return questions.every((entry) => {
    const selected = selections[entry.id] ?? new Set()
    const note = (notes[entry.id] ?? "").trim()
    return !selected.has(OTHER_TOKEN) || note !== ""
  })
}

function selectionsFromInitial(
  initialSelections: Record<string, readonly string[]> | undefined
): Record<string, Set<string>> {
  if (initialSelections == null) return {}
  return Object.fromEntries(
    Object.entries(initialSelections).map(([questionId, labels]) => [questionId, new Set(labels)])
  )
}

function OptionRow({
  label,
  description,
  index,
  isHighlighted,
  isSelected,
  onActivate
}: {
  label: string
  description?: string
  index: number
  isHighlighted: boolean
  isSelected: boolean
  onActivate: () => void
}) {
  return (
    <button
      type="button"
      onClick={onActivate}
      className={cn(
        "flex cursor-default items-center gap-2.5 rounded-md px-2.5 py-1.5 text-left text-sm outline-none",
        isHighlighted && "bg-primary text-primary-foreground"
      )}
    >
      <OptionStatusIcon isHighlighted={isHighlighted} isSelected={isSelected} />
      <span className="font-medium">{label}</span>
      {description != null && description !== "" && (
        <span
          className={cn(
            "min-w-0 flex-1 truncate",
            isHighlighted ? "text-primary-foreground/85" : "text-muted-foreground"
          )}
        >
          {description}
        </span>
      )}
      {index < 9 && (
        <span
          className={cn(
            "text-xs tabular-nums",
            isHighlighted ? "text-primary-foreground/60" : "text-muted-foreground/50"
          )}
        >
          {index + 1}
        </span>
      )}
    </button>
  )
}

function OptionStatusIcon({
  isHighlighted,
  isSelected
}: {
  isHighlighted: boolean
  isSelected: boolean
}) {
  if (!isSelected) {
    return (
      <CircleIcon
        className={cn(
          "size-3.5 shrink-0",
          isHighlighted ? "text-primary-foreground" : "text-muted-foreground/60"
        )}
      />
    )
  }

  return (
    <span
      aria-hidden="true"
      className={cn(
        "relative inline-flex size-3.5 shrink-0 items-center justify-center rounded-full",
        isHighlighted ? "bg-primary-foreground text-primary" : "bg-foreground text-background"
      )}
    >
      <CheckIcon className="size-2.5" strokeWidth={3} />
    </span>
  )
}

function NavButton({
  label,
  onClick,
  children
}: {
  label: string
  onClick: () => void
  children: React.ReactNode
}) {
  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      onClick={onClick}
      className="text-foreground flex size-7 cursor-default items-center justify-center rounded-full bg-[color-mix(in_srgb,var(--foreground)_16%,transparent)] outline-none"
    >
      {children}
    </button>
  )
}
