import type { OpenCodeAuthMethod, OpenCodeAuthPrompt } from "@codevisor/api"

import type { UpstreamMethod, UpstreamPrompt } from "./opencode-auth-server.js"

const promptCondition = (
  prompt: UpstreamPrompt
): { key: string; op: "eq" | "neq"; value: string } | undefined =>
  prompt.when?.key !== undefined &&
  (prompt.when.op === "eq" || prompt.when.op === "neq") &&
  prompt.when.value !== undefined
    ? { key: prompt.when.key, op: prompt.when.op, value: prompt.when.value }
    : undefined

const promptOptions = (prompt: UpstreamPrompt): OpenCodeAuthPrompt["options"] =>
  prompt.type === "select"
    ? (prompt.options ?? []).flatMap((option) =>
        option.value === undefined || option.label === undefined
          ? []
          : [
              {
                value: option.value,
                label: option.label,
                ...(option.hint === undefined ? {} : { hint: option.hint })
              }
            ]
      )
    : []

export const promptValue = (prompt: UpstreamPrompt): OpenCodeAuthPrompt | undefined => {
  if (
    (prompt.type !== "text" && prompt.type !== "select") ||
    prompt.key === undefined ||
    prompt.message === undefined
  ) {
    return undefined
  }
  const when = promptCondition(prompt)
  return {
    type: prompt.type,
    key: prompt.key,
    message: prompt.message,
    options: promptOptions(prompt),
    ...(prompt.placeholder === undefined ? {} : { placeholder: prompt.placeholder }),
    ...(when === undefined ? {} : { when })
  }
}

export const methodValues = (
  methods: ReadonlyArray<UpstreamMethod> | undefined
): OpenCodeAuthMethod[] => {
  const source: ReadonlyArray<UpstreamMethod> =
    methods === undefined || methods.length === 0 ? [{ type: "api", label: "API key" }] : methods
  return source.flatMap((method, index) => {
    if (method.type !== "api" && method.type !== "oauth") return []
    return [
      {
        id: String(index),
        type: method.type,
        label: method.type === "api" ? "API key" : (method.label ?? "Provider account"),
        prompts: (method.prompts ?? []).flatMap((prompt) => {
          const value = promptValue(prompt)
          return value === undefined ? [] : [value]
        })
      }
    ]
  })
}
