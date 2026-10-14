export const maxFailureDetailLength = 240

const stackFramePattern = /^at\s/

const nodeFooterPattern = /^Node\.js\s+v\d/

const errorLinePattern = /^(?:Uncaught\s+)?(?:[A-Za-z_$][\w$]*)?Error:\s*(?<message>\S.*)$/

const dyldMissingPattern = /^dyld\[\d+\]:\s*(?<message>Library not loaded:\s*\S.*)$/
const dyldReferencePattern = /^Referenced from:\s*(?:<[^>]*>\s*)?(?<binary>\S.*)$/

const isMinifiedSource = (line: string): boolean =>
  line.length > 180 && line.replace(/[^ \t]/g, "").length / line.length < 0.12

const isNoise = (line: string): boolean =>
  line.length === 0 ||
  stackFramePattern.test(line) ||
  nodeFooterPattern.test(line) ||
  isMinifiedSource(line)

const clamp = (value: string, limit: number): string => {
  const collapsed = value.replace(/\s+/g, " ").trim()
  if (collapsed.length <= limit) return collapsed
  const cut = collapsed.slice(0, limit - 1)
  const lastSpace = cut.lastIndexOf(" ")
  return `${(lastSpace > limit * 0.6 ? cut.slice(0, lastSpace) : cut).trimEnd()}…`
}

export const clampFailureDetail = (
  detail: string,
  limit = maxFailureDetailLength
): string | undefined => {
  const clamped = clamp(detail, limit)
  return clamped.length === 0 ? undefined : clamped
}

export const summarizeProcessFailure = (stderr: string, fallback: string): string => {
  const lines = stderr.split(/\r?\n/).map((line) => line.trim())
  const meaningful = lines.filter((line) => !isNoise(line))

  const missing = meaningful.findIndex((line) => dyldMissingPattern.test(line))
  if (missing >= 0) {
    const message = dyldMissingPattern.exec(meaningful[missing]!)!.groups!.message!
    const binary = dyldReferencePattern.exec(meaningful[missing + 1] ?? "")?.groups?.binary
    return clamp(
      binary === undefined ? message : `${message}, needed by ${binary}`,
      maxFailureDetailLength
    )
  }

  for (const line of meaningful) {
    const match = errorLinePattern.exec(line)
    if (match?.groups?.message !== undefined) {
      return clamp(match.groups.message, maxFailureDetailLength)
    }
  }

  const first = meaningful[0]
  return first === undefined ? fallback : clamp(first, maxFailureDetailLength)
}
