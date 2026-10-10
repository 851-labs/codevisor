/// Extracts a JSON string field's (possibly still-streaming) value from a
/// partial JSON buffer without a full parser: finds `"field":"` and decodes
/// escapes until the closing quote or the end of the buffer.
export const extractStringField = (json: string, field: string): string | undefined => {
  const key = `"${field}"`
  let index = json.indexOf(key)
  if (index === -1) return undefined
  index += key.length
  while (index < json.length && (json[index] === " " || json[index] === ":")) index += 1
  if (json[index] !== '"') return undefined
  index += 1
  return decodeJsonString(json, index).value
}

/// Extracts every occurrence of a string field (for MultiEdit's edits array).
export const extractAllStringFields = (json: string, field: string): Array<string> => {
  const key = `"${field}"`
  const values: Array<string> = []
  let cursor = 0
  while (true) {
    let index = json.indexOf(key, cursor)
    if (index === -1) return values
    index += key.length
    while (index < json.length && (json[index] === " " || json[index] === ":")) index += 1
    if (json[index] !== '"') {
      cursor = index
      continue
    }
    index += 1
    const decoded = decodeJsonString(json, index)
    values.push(decoded.value)
    cursor = decoded.end
  }
}

const decodeJsonString = (json: string, start: number): { value: string; end: number } => {
  let out = ""
  let index = start
  while (index < json.length) {
    const ch = json[index]
    if (ch === "\\") {
      const next = json[index + 1]
      if (next === undefined) break
      const decoded = decodeJsonEscape(json, index, next)
      if (next !== "u" || decoded.length !== 0) out += decoded
      if (next === "u" && decoded.length !== 0) index += 4
      index += 2
      continue
    }
    if (ch === '"') return { end: index + 1, value: out }
    out += ch
    index += 1
  }
  return { end: index, value: out }
}

const decodeJsonEscape = (json: string, index: number, escape: string): string => {
  switch (escape) {
    case "n":
      return "\n"
    case "t":
      return "\t"
    case "r":
      return "\r"
    case '"':
      return '"'
    case "\\":
      return "\\"
    case "/":
      return "/"
    case "u":
      return decodeUnicodeEscape(json, index)
    default:
      return escape
  }
}

const decodeUnicodeEscape = (json: string, index: number): string => {
  const hex = json.slice(index + 2, index + 6)
  if (hex.length === 4 && /^[0-9a-fA-F]{4}$/.test(hex)) {
    return String.fromCharCode(Number.parseInt(hex, 16))
  }
  return ""
}
