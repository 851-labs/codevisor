import { Schema } from "effect"

export const Labels = Schema.Record(Schema.String, Schema.String)
export type Labels = typeof Labels.Type
