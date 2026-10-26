import type { OpenCodeAuthMethod, OpenCodeAuthPrompt, OpenCodeAuthProvider } from "@codevisor/api"
import { Schema } from "effect"

const optionalString = Schema.optionalKey(Schema.String)

const FormField = Schema.Struct({
  key: optionalString,
  title: optionalString,
  type: optionalString,
  placeholder: optionalString,
  hidden: Schema.optionalKey(Schema.Boolean),
  required: Schema.optionalKey(Schema.Boolean),
  default: Schema.optionalKey(Schema.Unknown),
  options: Schema.optionalKey(
    Schema.Array(
      Schema.Struct({ value: optionalString, label: optionalString, description: optionalString })
    )
  ),
  when: Schema.optionalKey(
    Schema.Array(
      Schema.Struct({
        key: optionalString,
        op: optionalString,
        value: Schema.optionalKey(Schema.Unknown)
      })
    )
  )
})
type FormField = typeof FormField.Type

const scalarText = (value: unknown): string | undefined =>
  typeof value === "string" || typeof value === "number" || typeof value === "boolean"
    ? String(value)
    : undefined

const BOOLEAN_OPTIONS = [
  { value: "true", label: "Yes" },
  { value: "false", label: "No" }
]

const ANSWERABLE_TYPES = new Set(["string", "boolean", "number", "integer"])

export const OpenCodeIntegration = Schema.Struct({
  id: Schema.String,
  name: optionalString,
  methods: Schema.optionalKey(
    Schema.Array(
      Schema.Struct({
        type: optionalString,
        id: optionalString,
        label: optionalString,
        form: Schema.optionalKey(Schema.Array(FormField))
      })
    )
  ),
  connections: Schema.optionalKey(
    Schema.Array(Schema.Struct({ type: optionalString, method: optionalString }))
  )
})
export type OpenCodeIntegration = typeof OpenCodeIntegration.Type

export const OPENCODE_KEY_METHOD = "key"

type OpenCodeConnection = NonNullable<OpenCodeIntegration["connections"]>[number]

const connectionCredentialType = (active: OpenCodeConnection | undefined) => {
  if (active?.method === "oauth") return "oauth"
  if (active === undefined) return undefined
  return "api"
}

const fieldOptions = (field: FormField): Array<OpenCodeAuthPrompt["options"][number]> => {
  if (field.type === "boolean") return BOOLEAN_OPTIONS
  return (field.options ?? []).flatMap((option) =>
    option.value === undefined
      ? []
      : [
          {
            value: option.value,
            label: option.label ?? option.value,
            ...(option.description === undefined ? {} : { hint: option.description })
          }
        ]
  )
}

const prompts = (form: ReadonlyArray<FormField> = []): Array<OpenCodeAuthPrompt> =>
  form.flatMap((field): Array<OpenCodeAuthPrompt> => {
    if (field.hidden === true || field.key === undefined) return []
    if (field.type !== undefined && !ANSWERABLE_TYPES.has(field.type)) return []
    const options = fieldOptions(field)
    const when = field.when?.[0]
    const whenValue = scalarText(when?.value)
    const defaultValue = scalarText(field.default)
    return [
      {
        type: options.length > 0 ? "select" : "text",
        key: field.key,
        message: field.title ?? field.key,
        ...(field.placeholder === undefined ? {} : { placeholder: field.placeholder }),
        options,
        required: field.required === true,
        ...(defaultValue === undefined ? {} : { defaultValue }),
        ...(when?.key !== undefined &&
        (when.op === "eq" || when.op === "neq") &&
        whenValue !== undefined
          ? { when: { key: when.key, op: when.op, value: whenValue } }
          : {})
      }
    ]
  })

const answerValue = (field: FormField | undefined, text: string): string | number | boolean => {
  if (field?.type === "boolean") return text === "true"
  if (field?.type === "number" || field?.type === "integer") return Number(text)
  return text
}

export const openCodeFormAnswer = (
  integrations: ReadonlyArray<OpenCodeIntegration>,
  integrationID: string,
  methodID: string,
  inputs: Readonly<Record<string, string>> = {}
): Record<string, string | number | boolean> | undefined => {
  const methods = integrations.find((integration) => integration.id === integrationID)?.methods
  const method = methods?.find((candidate) =>
    methodID === OPENCODE_KEY_METHOD ? candidate.type === "key" : candidate.id === methodID
  )
  const entries = Object.entries(inputs).flatMap(([key, raw]) => {
    const text = raw.trim()
    if (text.length === 0) return []
    const field = method?.form?.find((candidate) => candidate.key === key)
    return [[key, answerValue(field, text)] as const]
  })
  return entries.length === 0 ? undefined : Object.fromEntries(entries)
}

export const openCodeProvidersFromIntegrations = (
  integrations: ReadonlyArray<OpenCodeIntegration>
): Array<OpenCodeAuthProvider> =>
  integrations
    .flatMap((integration): Array<OpenCodeAuthProvider> => {
      const methods = (integration.methods ?? []).flatMap((method): Array<OpenCodeAuthMethod> => {
        if (method.type === "key")
          return [
            {
              id: OPENCODE_KEY_METHOD,
              type: "api",
              label: method.label ?? "API Key",
              prompts: prompts(method.form)
            }
          ]
        if (method.type === "oauth" && method.id !== undefined)
          return [
            {
              id: method.id,
              type: "oauth",
              label: method.label ?? method.id,
              prompts: prompts(method.form)
            }
          ]
        return []
      })
      const active = integration.connections?.find((connection) => connection.type === "credential")
      const credentialType = connectionCredentialType(active)
      if (methods.length === 0 && credentialType === undefined) return []
      return [
        {
          id: integration.id,
          name: integration.name ?? integration.id,
          methods,
          ...(credentialType === undefined ? {} : { credentialType })
        }
      ]
    })
    .toSorted((left, right) => left.name.localeCompare(right.name))
