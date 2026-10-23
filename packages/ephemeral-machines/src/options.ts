import { Schema } from "effect"

import { EphemeralProviderError, type EphemeralProvider } from "./provider.js"

export type OptionsSource<Options> = Pick<
  EphemeralProvider<Options>,
  "id" | "displayName" | "options"
>

export const decodeProviderOptions = <Options>(
  provider: OptionsSource<Options>,
  overrides: unknown
): Options => {
  try {
    return Schema.decodeUnknownSync(provider.options)(overrides ?? {})
  } catch (cause) {
    throw new EphemeralProviderError(
      provider.id,
      `${provider.displayName} options are invalid: ${firstLine(cause)}`
    )
  }
}

export const defaultProviderOptions = <Options>(provider: OptionsSource<Options>): Options =>
  decodeProviderOptions(provider, {})

const firstLine = (cause: unknown): string => String(cause).replace(/\n[\s\S]*$/, "")
