export type ContainerEngine = "apple" | "docker" | "none"

export interface DevelopmentRunnerArguments {
  readonly containerEnginePreference: ContainerEngine | undefined
  readonly wantsContainers: boolean
}

const containerEngines: ReadonlySet<string> = new Set(["apple", "docker", "none"])
const engineFlag = "--container-engine="

export function parseDevelopmentRunnerArguments(
  arguments_: ReadonlyArray<string>,
  options: { readonly allowedArguments?: ReadonlyArray<string> } = {}
): DevelopmentRunnerArguments {
  const allowed = new Set(options.allowedArguments ?? [])
  const unknown = arguments_.filter(
    (argument) => !allowed.has(argument) && !isContainerArgument(argument)
  )
  if (unknown.length > 0)
    throw new Error(`Unknown development runner argument: ${unknown.join(", ")}`)

  const containerEnginePreference = containerEngineFrom(arguments_)
  return {
    containerEnginePreference,
    wantsContainers: !arguments_.includes("--no-containers") && containerEnginePreference !== "none"
  }
}

function isContainerArgument(argument: string): boolean {
  return (
    argument === "--containers" || argument === "--no-containers" || argument.startsWith(engineFlag)
  )
}

function containerEngineFrom(arguments_: ReadonlyArray<string>): ContainerEngine | undefined {
  const value = arguments_
    .find((argument) => argument.startsWith(engineFlag))
    ?.slice(engineFlag.length)
  if (value === undefined) return undefined
  if (!isContainerEngine(value)) {
    throw new Error(`Unknown container engine: ${value}. Expected apple, docker, or none.`)
  }
  return value
}

function isContainerEngine(value: string): value is ContainerEngine {
  return containerEngines.has(value)
}
