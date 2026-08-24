export interface SemanticVersion {
  readonly major: number
  readonly minor: number
  readonly patch: number
  readonly prerelease: ReadonlyArray<string>
}

const CORE_PATTERN = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/
const IDENTIFIER_PATTERN = /^[0-9A-Za-z-]+$/

/// Parses strict SemVer 2.0.0. A leading `v`, missing core component, or a
/// numeric prerelease identifier with a leading zero is invalid.
export const parseSemanticVersion = (value: string): SemanticVersion | undefined => {
  if (value !== value.trim()) return undefined
  const parts = value.split("+")
  const withoutBuild = parts.shift() as string
  const buildParts = parts
  if (buildParts.length > 1) return undefined
  if (
    buildParts.length === 1 &&
    (buildParts[0] === "" || !(buildParts[0] as string).split(".").every(validIdentifier))
  ) {
    return undefined
  }
  const dash = withoutBuild.indexOf("-")
  const coreText = dash === -1 ? withoutBuild : withoutBuild.slice(0, dash)
  const prereleaseText = dash === -1 ? undefined : withoutBuild.slice(dash + 1)
  const core = CORE_PATTERN.exec(coreText)
  if (core === null) return undefined
  const prerelease = prereleaseText?.split(".") ?? []
  if (
    prereleaseText === "" ||
    !prerelease.every(
      (identifier) =>
        validIdentifier(identifier) &&
        !(/^\d+$/.test(identifier) && identifier.length > 1 && identifier.startsWith("0"))
    )
  ) {
    return undefined
  }
  return {
    major: Number(core[1]),
    minor: Number(core[2]),
    patch: Number(core[3]),
    prerelease
  }
}

export const isSemanticVersion = (value: string): boolean =>
  parseSemanticVersion(value) !== undefined

/// Compares two valid semantic versions. Build metadata has no precedence.
export const compareSemanticVersions = (left: string, right: string): number => {
  const parsedLeft = parseSemanticVersion(left)
  const parsedRight = parseSemanticVersion(right)
  if (parsedLeft === undefined || parsedRight === undefined) {
    throw new Error(`Cannot compare invalid semantic versions: ${left}, ${right}`)
  }
  const leftCore = coreIdentifiers(left)
  const rightCore = coreIdentifiers(right)
  for (let index = 0; index < 3; index += 1) {
    const order = compareNumericIdentifier(leftCore[index] as string, rightCore[index] as string)
    if (order !== 0) return order
  }
  return comparePrerelease(parsedLeft.prerelease, parsedRight.prerelease)
}

const validIdentifier = (identifier: string): boolean =>
  identifier.length > 0 && IDENTIFIER_PATTERN.test(identifier)

const comparePrerelease = (left: ReadonlyArray<string>, right: ReadonlyArray<string>): number => {
  if (left.length === 0 || right.length === 0) {
    return left.length === right.length ? 0 : left.length === 0 ? 1 : -1
  }
  for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
    const a = left[index]
    const b = right[index]
    if (a === undefined || b === undefined) return a === undefined ? -1 : 1
    const aNumeric = /^\d+$/.test(a)
    const bNumeric = /^\d+$/.test(b)
    if (aNumeric && bNumeric) {
      const order = compareNumericIdentifier(a, b)
      if (order !== 0) return order
    } else if (aNumeric !== bNumeric) {
      return aNumeric ? -1 : 1
    } else if (a !== b) {
      return a > b ? 1 : -1
    }
  }
  return 0
}

const coreIdentifiers = (version: string): ReadonlyArray<string> =>
  (version.split(/[+-]/)[0] as string).split(".")

const compareNumericIdentifier = (left: string, right: string): number =>
  left.length === right.length
    ? left === right
      ? 0
      : left > right
        ? 1
        : -1
    : left.length > right.length
      ? 1
      : -1
