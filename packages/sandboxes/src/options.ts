import { readFields, type SandboxFieldValues } from "./fields.js"
import type { SandboxProviderDefinition } from "./provider.js"

export const readProfileOptions = (
  definition: SandboxProviderDefinition,
  raw: Readonly<Record<string, unknown>>
): SandboxFieldValues => readFields(definition.profileFields, raw)

export const readAccountValues = (
  definition: SandboxProviderDefinition,
  raw: Readonly<Record<string, unknown>>
): SandboxFieldValues => readFields(definition.accountFields, raw)
