import { decode } from "@codevisor/api"
import { Schema } from "effect"

export { field } from "../unknown-values.js"

const Identified = Schema.Struct({ id: Schema.String })

export const idOf = (value: unknown): string => decode(Identified)(value).id

export const itemsOf = (value: unknown): ReadonlyArray<unknown> =>
  decode(Schema.Array(Schema.Unknown))(value)
