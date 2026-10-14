import { describe, expect, it } from "vitest"

import { extractAllStringFields, extractStringField } from "./partial-json-string.js"

describe("partial JSON string extraction", () => {
  it("extracts complete and streaming values", () => {
    const complete = '{"file_path":"/a.txt","old_string":"one\\ntwo"}'
    expect(extractStringField(complete, "file_path")).toBe("/a.txt")
    expect(extractStringField(complete, "old_string")).toBe("one\ntwo")

    const partial = '{"file_path":"/a.txt","new_string":"line one\\nline tw'
    expect(extractStringField(partial, "new_string")).toBe("line one\nline tw")
    expect(extractStringField(partial, "missing")).toBeUndefined()
  })

  it("decodes escapes including unicode", () => {
    const json = '{"s":"tab\\there \\u0041 quote\\" done"}'
    expect(extractStringField(json, "s")).toBe('tab\there A quote" done')
  })

  it("extracts every occurrence for MultiEdit", () => {
    const json =
      '{"edits":[{"old_string":"a\\nb","new_string":"c"},{"old_string":"d","new_string":"e\\nf"}]}'
    expect(extractAllStringFields(json, "old_string")).toEqual(["a\nb", "d"])
    expect(extractAllStringFields(json, "new_string")).toEqual(["c", "e\nf"])
  })
})
