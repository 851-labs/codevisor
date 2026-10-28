import {
  cappedFields,
  readFields,
  type SandboxFieldMaximums,
  type SandboxFieldValues
} from "./fields.js"
import type { SandboxProviderDefinition } from "./provider.js"

export const readProfileOptions = (
  definition: SandboxProviderDefinition,
  raw: Readonly<Record<string, unknown>>,
  maximums: SandboxFieldMaximums = {}
): SandboxFieldValues => readFields(cappedFields(definition.profileFields, maximums), raw)

export const readAccountValues = (
  definition: SandboxProviderDefinition,
  raw: Readonly<Record<string, unknown>>
): SandboxFieldValues => readFields(definition.accountFields, raw)
