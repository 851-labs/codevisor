/// Shared public argument surface for every native development runner.
/// Platform-specific plumbing (currently dev.ts's --no-ios) is supplied by
/// the caller; container behavior and validation stay identical everywhere.

export type ContainerEngine = "apple" | "docker" | "none"

export interface DevelopmentRunnerOptions {
  allowedArguments?: readonly string[]
}

export interface DevelopmentRunnerArguments {
  containerEnginePreference: ContainerEngine | undefined
  wantsContainers: boolean
}

const CONTAINER_ENGINES: readonly ContainerEngine[] = ["apple", "docker", "none"]
const ENGINE_FLAG = "--container-engine="

const isContainerEngine = (value: string): value is ContainerEngine =>
  (CONTAINER_ENGINES as readonly string[]).includes(value)

export function parseDevelopmentRunnerArguments(
  arguments_: readonly string[],
  options: DevelopmentRunnerOptions = {}
): DevelopmentRunnerArguments {
  const allowedArguments = new Set(options.allowedArguments ?? [])
  const unknownArguments = arguments_.filter(
    (argument) =>
      !allowedArguments.has(argument) &&
      argument !== "--containers" &&
      argument !== "--no-containers" &&
      !argument.startsWith(ENGINE_FLAG)
  )
  if (unknownArguments.length > 0) {
    throw new Error(`Unknown development runner argument: ${unknownArguments.join(", ")}`)
  }

  const containerEnginePreference = arguments_
    .find((argument) => argument.startsWith(ENGINE_FLAG))
    ?.slice(ENGINE_FLAG.length)
  if (containerEnginePreference !== undefined && !isContainerEngine(containerEnginePreference)) {
    throw new Error(
      `Unknown container engine: ${containerEnginePreference}. Expected apple, docker, or none.`
    )
  }

  return {
    containerEnginePreference,
    // Containers are the default. Either spelling for an explicit opt-out
    // wins even when a wrapper also supplied --containers.
    wantsContainers: !arguments_.includes("--no-containers") && containerEnginePreference !== "none"
  }
}
