export interface StackFrame {
  readonly function?: string
  readonly filename: string
  readonly lineno?: number
  readonly colno?: number
  readonly in_app: boolean
}

export const parseStackFrames = (stack: string | undefined): ReadonlyArray<StackFrame> =>
  (stack ?? "")
    .split("\n")
    .map(parseLine)
    .filter((frame) => frame !== undefined)
    .toReversed()

const framePattern = /^\s*at (?:(.+?) \()?(.+?)(?::(\d+))?(?::(\d+))?\)?$/

const parseLine = (line: string): StackFrame | undefined => {
  const match = framePattern.exec(line)
  if (match === null) return undefined

  const [, name, location, lineNumber, columnNumber] = match
  const filename = shortenLocation(location!)
  return {
    ...(name === undefined ? {} : { function: name }),
    filename,
    ...(lineNumber === undefined ? {} : { lineno: Number(lineNumber) }),
    ...(columnNumber === undefined ? {} : { colno: Number(columnNumber) }),
    in_app: isInApp(filename)
  }
}

const moduleRoots = ["/node_modules/", "/apps/", "/packages/", "/plugins/"]

const shortenLocation = (location: string): string => {
  const path = location.replace(/^file:\/\//, "")
  for (const root of moduleRoots) {
    const index = path.lastIndexOf(root)
    if (index !== -1) return path.slice(index + 1)
  }
  return path.slice(path.lastIndexOf("/") + 1)
}

const isInApp = (filename: string): boolean => {
  if (filename.startsWith("node:")) return false
  return !filename.startsWith("node_modules/") || filename.startsWith("node_modules/@codevisor/")
}
