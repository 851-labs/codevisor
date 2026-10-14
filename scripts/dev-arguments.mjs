export function parseDevelopmentRunnerArguments(arguments_, options = {}) {
  const allowedArguments = new Set(options.allowedArguments ?? [])
  const unknownArguments = arguments_.filter(
    (argument) =>
      !allowedArguments.has(argument) &&
      argument !== "--containers" &&
      argument !== "--no-containers" &&
      !argument.startsWith("--container-engine=")
  )
  if (unknownArguments.length > 0) {
    throw new Error(`Unknown development runner argument: ${unknownArguments.join(", ")}`)
  }

  const containerEnginePreference = arguments_
    .find((argument) => argument.startsWith("--container-engine="))
    ?.slice("--container-engine=".length)
  if (
    containerEnginePreference !== undefined &&
    !["apple", "docker", "none"].includes(containerEnginePreference)
  ) {
    throw new Error(
      `Unknown container engine: ${containerEnginePreference}. Expected apple, docker, or none.`
    )
  }

  return {
    containerEnginePreference,
    wantsContainers: !arguments_.includes("--no-containers") && containerEnginePreference !== "none"
  }
}
