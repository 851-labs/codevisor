import type { QuestionAnswerEntry, QuestionSpec } from "@codevisor/api"

import { isRecord } from "./internal.js"

interface ElicitationField {
  readonly spec: QuestionSpec
  readonly coerce: (entry: QuestionAnswerEntry) => unknown
}

export const elicitationFields = (schema: Record<string, unknown>): Array<ElicitationField> => {
  if (!isRecord(schema.properties)) return []
  return Object.entries(schema.properties).flatMap(([key, raw]): Array<ElicitationField> => {
    if (!isRecord(raw)) return []
    return elicitationField(key, raw)
  })
}

const elicitationField = (key: string, raw: Record<string, unknown>): Array<ElicitationField> => {
  const title = typeof raw.title === "string" ? raw.title : undefined
  const description = typeof raw.description === "string" ? raw.description : undefined
  const question = description ?? title ?? key
  const base = { id: key, question }
  const enumeration = singleSelectField(raw, base)
  if (enumeration !== undefined) return enumeration
  if (raw.type === "array" && isRecord(raw.items)) {
    return multiSelectField(raw.items, base)
  }
  if (raw.type === "boolean") return booleanField(base)
  if (raw.type === "number" || raw.type === "integer") return numericField(base)
  return freeTextField(base)
}

const singleSelectField = (
  raw: Record<string, unknown>,
  base: Pick<QuestionSpec, "id" | "question">
): Array<ElicitationField> | undefined => {
  const constOptions = Array.isArray(raw.oneOf) ? enumOptions(raw.oneOf) : undefined
  const plainEnum = Array.isArray(raw.enum) ? plainEnumOptions(raw.enum, raw.enumNames) : undefined
  if (constOptions !== undefined || plainEnum !== undefined) {
    const options = constOptions ?? plainEnum ?? []
    return [
      {
        coerce: (entry) => options.find((option) => option.label === entry.answers[0])?.value,
        spec: { ...base, allowsOther: false, options: options.map(optionSpec) }
      }
    ]
  }
  return undefined
}

const multiSelectField = (
  items: Record<string, unknown>,
  base: Pick<QuestionSpec, "id" | "question">
): Array<ElicitationField> => {
  const options =
    (Array.isArray(items.anyOf) ? enumOptions(items.anyOf) : undefined) ??
    (Array.isArray(items.oneOf) ? enumOptions(items.oneOf) : undefined) ??
    (Array.isArray(items.enum) ? plainEnumOptions(items.enum, items.enumNames) : undefined) ??
    []
  if (options.length === 0) return []
  return [
    {
      coerce: (entry) =>
        entry.answers.flatMap((label) => {
          const value = options.find((option) => option.label === label)?.value
          return value === undefined ? [] : [value]
        }),
      spec: { ...base, allowsOther: false, multiSelect: true, options: options.map(optionSpec) }
    }
  ]
}

const yesNoAnswer = (entry: QuestionAnswerEntry) => {
  if (entry.answers[0] === "Yes") return true
  if (entry.answers[0] === "No") return false
  return undefined
}

const booleanField = (base: Pick<QuestionSpec, "id" | "question">): Array<ElicitationField> => [
  {
    coerce: yesNoAnswer,
    spec: {
      ...base,
      allowsOther: false,
      options: [{ label: "Yes" }, { label: "No" }]
    }
  }
]

const numericField = (base: Pick<QuestionSpec, "id" | "question">): Array<ElicitationField> => [
  {
    coerce: (entry) => {
      const text = entry.note ?? entry.answers[0] ?? ""
      const parsed = Number(text)
      return Number.isFinite(parsed) ? parsed : undefined
    },
    spec: { ...base, allowsOther: true, options: [] }
  }
]

const freeTextField = (base: Pick<QuestionSpec, "id" | "question">): Array<ElicitationField> => [
  {
    coerce: (entry) => {
      const text = (entry.note ?? entry.answers[0] ?? "").trim()
      return text.length > 0 ? text : undefined
    },
    spec: { ...base, allowsOther: true, options: [] }
  }
]

interface LabeledValue {
  readonly label: string
  readonly description?: string
  readonly value: string
}

const enumOptions = (entries: ReadonlyArray<unknown>): Array<LabeledValue> | undefined => {
  const options = entries.flatMap((entry) =>
    isRecord(entry) && typeof entry.const === "string"
      ? [
          {
            label: typeof entry.title === "string" ? entry.title : entry.const,
            value: entry.const
          }
        ]
      : []
  )
  return options.length > 0 ? options : undefined
}

const plainEnumOptions = (
  values: ReadonlyArray<unknown>,
  names: unknown
): Array<LabeledValue> | undefined => {
  const labels = Array.isArray(names) ? names : []
  const options = values.flatMap((value, index) =>
    typeof value === "string"
      ? [{ label: typeof labels[index] === "string" ? labels[index] : value, value }]
      : []
  )
  return options.length > 0 ? options : undefined
}

const optionSpec = (option: LabeledValue): { label: string; description?: string } => ({
  label: option.label,
  ...(option.description === undefined ? {} : { description: option.description })
})
