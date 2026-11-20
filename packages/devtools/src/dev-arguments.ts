export type DevelopmentTarget = "macos" | "ios" | "linux"

export interface DevelopmentRunnerArguments {
  readonly target: DevelopmentTarget
  readonly reuseMacOSBuild: boolean
}

const targetFlags: ReadonlyMap<string, DevelopmentTarget> = new Map([
  ["--ios", "ios"],
  ["--linux", "linux"]
])
const reuseFlag = "--reuse-macos-build"
const usage =
  "Run bun run dev, dev:ios, or dev:linux; the only flag they take is --reuse-macos-build."

export function parseDevelopmentRunnerArguments(
  arguments_: ReadonlyArray<string>
): DevelopmentRunnerArguments {
  const unknown = arguments_.filter(
    (argument) => argument !== reuseFlag && !targetFlags.has(argument)
  )
  if (unknown.length > 0)
    throw new Error(`Unknown development runner argument: ${unknown.join(", ")}. ${usage}`)

  const targets = [...new Set(arguments_.flatMap((argument) => targetFlags.get(argument) ?? []))]
  if (targets.length > 1) throw new Error(`Pick one development runner. ${usage}`)
  return { target: targets[0] ?? "macos", reuseMacOSBuild: arguments_.includes(reuseFlag) }
}
