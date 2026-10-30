const secretPatterns: ReadonlyArray<readonly [RegExp, string]> = [
  [/\bsk-ant-[\w-]+/g, "sk-ant-<redacted>"],
  [/\beyJ[\w-]+\.[\w-]+\.[\w-]+/g, "<redacted-jwt>"],
  [/\b(Bearer|Basic)\s+[\w.~+/=-]+/gi, "$1 <redacted>"],
  [/\b([a-z][a-z0-9+.-]*:\/\/)[^\s/@]+@/gi, "$1<redacted>@"],
  [
    /\b([\w-]*(?:token|api[_-]?key|secret|password|authorization|cookie)[\w-]*)(["']?\s*[:=]\s*["']?)[^\s"',}]+/gi,
    "$1$2<redacted>"
  ]
]

export const redactSecrets = (text: string): string =>
  secretPatterns.reduce(
    (redacted, [pattern, replacement]) => redacted.replace(pattern, replacement),
    text
  )
