import { describe, expect, it } from "vitest"

import {
  booleanField,
  cappedFields,
  choiceField,
  fieldDefaults,
  keepingSecrets,
  machineField,
  numberField,
  numberValue,
  optionalString,
  readFields,
  secretField,
  secretsSet,
  stringValue,
  textField,
  urlField,
  withoutSecrets
} from "./fields.js"

const fields = [
  urlField("url", "Controller URL", { required: true }),
  textField("name", "Service account"),
  secretField("token", "Token", { required: true }),
  numberField("cpu", "CPUs", { default: 4, min: 1, max: 16 }),
  numberField("disk", "Disk (GB)", { min: 20 }),
  numberField("lifetime", "Lifetime", { max: 45 }),
  booleanField("public", "Public"),
  choiceField("region", "Region", [
    { value: "us", label: "United States" },
    { value: "eu", label: "Europe" }
  ]),
  machineField("machineId", "Mac", "tart")
]

const valid = { url: "https://orchard.example.com/", token: " secret " }

describe("sandbox fields", () => {
  it("trims text, normalizes URLs, parses numbers and fills defaults", () => {
    expect(readFields(fields, { ...valid, cpu: "8", region: "eu", public: true })).toEqual({
      url: "https://orchard.example.com",
      token: "secret",
      cpu: 8,
      region: "eu",
      public: true
    })
    expect(readFields(fields, { ...valid, name: "  ", disk: null })).toEqual({
      url: "https://orchard.example.com",
      token: "secret",
      cpu: 4
    })
    expect(fieldDefaults(fields)).toEqual({ cpu: 4 })
  })

  it("explains what's wrong in terms of the field's label", () => {
    const failures: Array<[Record<string, unknown>, string]> = [
      [{ token: "x" }, "Controller URL is required"],
      [{ ...valid, token: " " }, "Token is required"],
      [{ ...valid, url: "ftp://orchard" }, "Controller URL must be an http or https URL"],
      [{ ...valid, url: "not a url" }, "Controller URL must be an http or https URL"],
      [{ ...valid, cpu: "many" }, "CPUs must be a number"],
      [{ ...valid, cpu: 32 }, "CPUs must be between 1 and 16"],
      [{ ...valid, disk: 10 }, "Disk (GB) must be at least 20"],
      [{ ...valid, lifetime: 60 }, "Lifetime must be at most 45"],
      [{ ...valid, public: "yes" }, "Public must be on or off"],
      [{ ...valid, name: 7 }, "Service account must be text"],
      [{ ...valid, region: "mars" }, "Region must be one of United States, Europe"]
    ]
    const unlisted = { key: "size", label: "Size", type: "choice" as const, required: false }

    for (const [raw, message] of failures) expect(() => readFields(fields, raw)).toThrow(message)
    expect(() => readFields([unlisted], { size: "xl" })).toThrow("Size must be one of ")
  })

  it("lowers a field's maximum to the host's, never raises it, and leaves other fields alone", () => {
    const capped = cappedFields(fields, { cpu: 8, disk: 64, lifetime: 90 })

    expect(() => readFields(capped, { ...valid, cpu: 9 })).toThrow("CPUs must be between 1 and 8")
    expect(() => readFields(capped, { ...valid, disk: 65 })).toThrow(
      "Disk (GB) must be between 20 and 64"
    )
    expect(readFields(capped, { ...valid, lifetime: 45 })).toMatchObject({ lifetime: 45 })
    expect(() => readFields(capped, { ...valid, lifetime: 46 })).toThrow(
      "Lifetime must be at most 45"
    )
  })

  it("never hands secrets back, and keeps a saved secret when an edit leaves it blank", () => {
    const saved = readFields(fields, valid)

    expect(withoutSecrets(fields, saved)).toEqual({ url: "https://orchard.example.com", cpu: 4 })
    expect(secretsSet(fields, saved)).toEqual(["token"])
    expect(secretsSet(fields, { url: "https://x" })).toEqual([])
    expect(keepingSecrets(fields, saved, { url: "https://new", token: "" })).toEqual({
      url: "https://new",
      token: "secret"
    })
    expect(keepingSecrets(fields, saved, { url: "https://new", token: "rotated" })).toEqual({
      url: "https://new",
      token: "rotated"
    })
  })

  it("reads typed values with fallbacks", () => {
    const values = { image: "base", cpu: 2, empty: "" }

    expect(stringValue(values, "image")).toBe("base")
    expect(stringValue(values, "cpu")).toBe("")
    expect(numberValue(values, "cpu", 4)).toBe(2)
    expect(numberValue(values, "image", 4)).toBe(4)
    expect(optionalString(values, "empty")).toBeUndefined()
    expect(optionalString(values, "image")).toBe("base")
  })
})
