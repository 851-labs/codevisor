/// Semver-style version comparison, tolerant of `v` prefixes and build
/// metadata. Numeric cores compare first; on equal cores a release outranks
/// any pre-release (`0.1.94` > `0.1.94-rc.37` — an rc/alpha install must
/// still be offered its own stable), and pre-releases compare
/// identifier-by-identifier per semver §11. Lifted from the server
/// self-updater so both share one notion of "newer".
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
  /* v8 ignore next -- split() always yields a first element; ?? guards the type. */
  const normalized = version.trim().replace(/^v/, "").split("+")[0] ?? ""
  const dash = normalized.indexOf("-")
  const core = dash === -1 ? normalized : normalized.slice(0, dash)
  return {
    core: core.split(".").map((part) => Number(part) || 0),
    prerelease: dash === -1 ? [] : normalized.slice(dash + 1).split(".")
  }
}

const comparePrerelease = (left: ReadonlyArray<string>, right: ReadonlyArray<string>): number => {
  // A release outranks any pre-release of the same core.
  if (left.length === 0 || right.length === 0) {
    return left.length === right.length ? 0 : left.length === 0 ? 1 : -1
  }
  for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
    const a = left[index]
    const b = right[index]
    // The longer identifier list wins once the shared prefix ties.
    if (a === undefined || b === undefined) return a === undefined ? -1 : 1
    const aNumeric = /^\d+$/.test(a) ? Number(a) : undefined
    const bNumeric = /^\d+$/.test(b) ? Number(b) : undefined
    if (aNumeric !== undefined && bNumeric !== undefined) {
      if (aNumeric !== bNumeric) return aNumeric > bNumeric ? 1 : -1
    } else if (aNumeric !== undefined || bNumeric !== undefined) {
      // Numeric identifiers rank below alphanumeric ones.
      return aNumeric !== undefined ? -1 : 1
    } else if (a !== b) {
      return a > b ? 1 : -1
    }
  }
  return 0
}
