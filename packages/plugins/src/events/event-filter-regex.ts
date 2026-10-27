export const maxPatternLength = 200

export const patternProblem = (pattern: string): string | undefined => {
  if (pattern.length > maxPatternLength) return `is longer than ${maxPatternLength} characters`
  if (compiled(pattern) === undefined) return "is not a valid regular expression"
  if (backReference.test(pattern)) return "uses a back-reference"
  if (hasRepeatedGroup(pattern)) return "repeats a group that itself repeats or alternates"
  return undefined
}

const backReference = /\\(?:[1-9]|k<)/

const compiled = (pattern: string): RegExp | undefined => {
  try {
    return new RegExp(pattern)
  } catch {
    return undefined
  }
}

const hasRepeatedGroup = (pattern: string): boolean => {
  const groups: boolean[] = [false]
  let index = 0
  while (index < pattern.length) {
    const char = pattern.charAt(index)
    index = nextTokenIndex(pattern, index)
    if (char === "(") groups.push(false)
    if (varyingChars.has(char)) groups[groups.length - 1] = true
    if (char !== ")") continue

    const varies = groups.pop() === true
    if (varies && repeatingChars.has(pattern.charAt(index))) return true
    if (varies) groups[groups.length - 1] = true
  }
  return false
}

const nextTokenIndex = (pattern: string, index: number): number => {
  if (pattern[index] === "\\") return index + 2
  if (pattern[index] === "[") return classEnd(pattern, index + 1)
  return index + 1
}

const varyingChars = new Set(["*", "+", "{", "|"])

const repeatingChars = new Set(["*", "+", "{"])

const classEnd = (pattern: string, start: number): number => {
  let index = start
  while (index < pattern.length && pattern[index] !== "]") {
    index += pattern[index] === "\\" ? 2 : 1
  }
  return index + 1
}
