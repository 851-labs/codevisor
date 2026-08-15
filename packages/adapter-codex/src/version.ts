import { execFileSync } from "node:child_process"

export const readCodexVersion = (command: string, env: NodeJS.ProcessEnv): string | undefined => {
  try {
    const output = execFileSync(command, ["--version"], {
      encoding: "utf8",
      env,
      timeout: 1000
    })
    return codexVersionFromOutput(output)
  } catch {
    return undefined
  }
}

const codexVersionFromOutput = (output: string): string | undefined => {
  const match = output.match(/(?:^|\s)[vV]?(\d+(?:\.\d+)+)(?:-[^\s]+)?/)
  return match?.[1]
}

export const isCodexVersionNewer = (candidate: string, current: string): boolean => {
  const lhs = numericVersionComponents(candidate)
  const rhs = numericVersionComponents(current)
  for (let index = 0; index < Math.max(lhs.length, rhs.length); index += 1) {
    const left = lhs[index] ?? 0
    const right = rhs[index] ?? 0
    if (left !== right) return left > right
  }
  return false
}

const numericVersionComponents = (version: string): ReadonlyArray<number> => {
  const normalized = (codexVersionFromOutput(version) ?? version).trim().replace(/^[vV]/, "")
  const base = normalized.split("-")[0] ?? normalized
  return base.split(".").map((part) => Number.parseInt(part, 10) || 0)
}
