import type { OpenCodeAuthMethod, OpenCodeAuthPrompt, OpenCodeAuthProvider } from "@codevisor/api"
import { Schema } from "effect"

const optionalString = Schema.optionalKey(Schema.String)

const FormField = Schema.Struct({
  key: optionalString,
  title: optionalString,
  type: optionalString,
  placeholder: optionalString,
  hidden: Schema.optionalKey(Schema.Boolean),
  options: Schema.optionalKey(
    Schema.Array(
      Schema.Struct({ value: optionalString, label: optionalString, description: optionalString })
    )
  ),
  when: Schema.optionalKey(
    Schema.Array(Schema.Struct({ key: optionalString, op: optionalString, value: optionalString }))
  )
})
type FormField = typeof FormField.Type

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

const prompts = (form: ReadonlyArray<FormField> = []): Array<OpenCodeAuthPrompt> =>
  form.flatMap((field): Array<OpenCodeAuthPrompt> => {
    if (field.hidden === true || field.key === undefined) return []
    const options = (field.options ?? []).flatMap((option) =>
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
    const when = field.when?.[0]
    return [
      {
        type: options.length > 0 ? "select" : "text",
        key: field.key,
        message: field.title ?? field.key,
        ...(field.placeholder === undefined ? {} : { placeholder: field.placeholder }),
        options,
        ...(when?.key !== undefined &&
        (when.op === "eq" || when.op === "neq") &&
        when.value !== undefined
          ? { when: { key: when.key, op: when.op, value: when.value } }
          : {})
      }
    ]
  })

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
