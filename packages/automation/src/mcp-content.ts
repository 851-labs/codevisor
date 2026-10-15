import { ContentBlockSchema, type ContentBlock } from "@modelcontextprotocol/sdk/types.js"

import { recordOrEmpty } from "./unknown-values.js"

export const contentBlock = (value: unknown): ContentBlock | undefined => {
  const parsed = ContentBlockSchema.safeParse(value)
  return parsed.success ? parsed.data : undefined
}

export const outputContentBlocks = (output: ReadonlyArray<unknown> = []): ContentBlock[] =>
  output.flatMap((item) => {
    const block = contentBlock(recordOrEmpty(item).content)
    return block === undefined ? [] : [block]
  })
