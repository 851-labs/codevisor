import { Schema } from "effect"

export const hasUiMeta = (meta: unknown): boolean => decodedUi(meta) !== undefined

export const prefersBorder = (meta: unknown): boolean | undefined => decodedUi(meta)?.prefersBorder

const UiMeta = Schema.Struct({
  ui: Schema.optional(Schema.Struct({ prefersBorder: Schema.optional(Schema.Boolean) }))
})

const decodedUi = (meta: unknown) => {
  try {
    return Schema.decodeUnknownSync(UiMeta)(meta ?? {}).ui
  } catch {
    return undefined
  }
}
