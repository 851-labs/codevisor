import type { OpenCodeAuthMethod, OpenCodeAuthPrompt, OpenCodeAuthProvider } from "@codevisor/api"

/// OpenCode 2's integration catalog (`GET /api/integration`) in the provider
/// shape the accounts UI already renders. A method keeps OpenCode's own id
/// (`chatgpt-browser`, `device`; `key` for an API key) so sign-in can name it.

interface FormField {
  readonly key?: string
  readonly title?: string
  readonly type?: string
  readonly placeholder?: string
  readonly hidden?: boolean
  readonly options?: ReadonlyArray<{
    readonly value?: string
    readonly label?: string
    readonly description?: string
  }>
  readonly when?: ReadonlyArray<{
    readonly key?: string
    readonly op?: string
    readonly value?: string
  }>
}

export interface OpenCodeIntegration {
  readonly id: string
  readonly name?: string
  readonly methods?: ReadonlyArray<{
    readonly type?: string
    readonly id?: string
    readonly label?: string
    readonly form?: ReadonlyArray<FormField>
  }>
  readonly connections?: ReadonlyArray<{ readonly type?: string; readonly method?: string }>
}

/// The method id an API key is entered under.
export const OPENCODE_KEY_METHOD = "key"

const prompts = (form: ReadonlyArray<FormField> = []): Array<OpenCodeAuthPrompt> =>
  form.flatMap((field): Array<OpenCodeAuthPrompt> => {
    // Hidden fields carry their own defaults; there is nothing to ask.
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
        // Environment variables and commands aren't something to click.
        return []
      })
      // The first connection is the one in use.
      const active = integration.connections?.find((connection) => connection.type === "credential")
      const credentialType =
        active?.method === "oauth" ? "oauth" : active === undefined ? undefined : "api"
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
