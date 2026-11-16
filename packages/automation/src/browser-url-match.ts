import { isPlainRecord } from "./unknown-values.js"

export type UrlMatcher = (url: string) => boolean

export const urlMatcher = (pattern: unknown, label: string): UrlMatcher => {
  if (typeof pattern === "string") return stringMatcher(pattern)
  if (isPlainRecord(pattern) && typeof pattern.regex === "string") {
    const expression = new RegExp(
      pattern.regex,
      typeof pattern.flags === "string" ? pattern.flags.replaceAll("g", "") : ""
    )
    return (url) => expression.test(url)
  }
  throw new Error(
    `${label} must be a URL, a glob pattern such as **/api/*, or a regular expression`
  )
}

const stringMatcher = (pattern: string): UrlMatcher => {
  if (!/[*{]/.test(pattern)) return (url) => url === pattern

  const expression = new RegExp(`^${globSource(pattern)}$`)
  return (url) => expression.test(url)
}

const globSource = (pattern: string): string => {
  let source = ""
  let inGroup = false
  for (let index = 0; index < pattern.length; index++) {
    const character = pattern.charAt(index)
    if (character === "*" && pattern.charAt(index + 1) === "*") {
      source += ".*"
      index += 1
    } else if (character === "*") source += "[^/]*"
    else if (character === "{") {
      source += "(?:"
      inGroup = true
    } else if (character === "}" && inGroup) {
      source += ")"
      inGroup = false
    } else if (character === "," && inGroup) source += "|"
    else source += character.replaceAll(/[\\^$.|?+()[\]{}]/g, String.raw`\$&`)
  }
  return source
}
