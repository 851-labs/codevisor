export const isNewerVersion = (candidate: string, current: string): boolean => {
  const left = parseVersion(candidate)
  const right = parseVersion(current)
  for (let index = 0; index < Math.max(left.core.length, right.core.length); index += 1) {
    const a = left.core[index] ?? 0
    const b = right.core[index] ?? 0
    if (a !== b) {
      return a > b
    }
  }
  return comparePrerelease(left.prerelease, right.prerelease) > 0
}

const parseVersion = (
  version: string
): { readonly core: ReadonlyArray<number>; readonly prerelease: ReadonlyArray<string> } => {
  /* v8 ignore next */
  const normalized = version.trim().replace(/^v/, "").split("+")[0] ?? ""
  const dash = normalized.indexOf("-")
  const core = dash === -1 ? normalized : normalized.slice(0, dash)
  return {
    core: core.split(".").map((part) => Number(part) || 0),
    prerelease: dash === -1 ? [] : normalized.slice(dash + 1).split(".")
  }
}

const compareEmptyPrerelease = (
  left: ReadonlyArray<string>,
  right: ReadonlyArray<string>
): number => {
  if (left.length === right.length) return 0
  if (left.length === 0) return 1
  return -1
}

const comparePrerelease = (left: ReadonlyArray<string>, right: ReadonlyArray<string>): number => {
  if (left.length === 0 || right.length === 0) {
    return compareEmptyPrerelease(left, right)
  }
  for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
    const a = left[index]
    const b = right[index]
    if (a === undefined || b === undefined) return a === undefined ? -1 : 1
    const aNumeric = /^\d+$/.test(a) ? Number(a) : undefined
    const bNumeric = /^\d+$/.test(b) ? Number(b) : undefined
    if (aNumeric !== undefined && bNumeric !== undefined) {
      if (aNumeric !== bNumeric) return aNumeric > bNumeric ? 1 : -1
    } else if (aNumeric !== undefined || bNumeric !== undefined) {
      return aNumeric !== undefined ? -1 : 1
    } else if (a !== b) {
      return a > b ? 1 : -1
    }
  }
  return 0
}
