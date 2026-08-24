import type { PluginManifest } from "@codevisor/api"

export type ResolvedPluginCommand =
  | { readonly kind: "shell"; readonly command: string }
  | { readonly kind: "argv"; readonly argv: ReadonlyArray<string> }

export const pluginRunCommand = (manifest: PluginManifest): ResolvedPluginCommand =>
  manifest.protocolVersion === 1
    ? { command: manifest.run.command, kind: "shell" }
    : { argv: manifest.run.argv, kind: "argv" }

export const pluginSetupCommands = (
  manifest: PluginManifest,
  platform: string
): ReadonlyArray<ResolvedPluginCommand> => {
  if (manifest.protocolVersion === 1) {
    return manifest.install === undefined
      ? []
      : [{ command: manifest.install.command, kind: "shell" }]
  }
  return (manifest.setup ?? [])
    .filter((step) => step.platforms === undefined || step.platforms.includes(platform))
    .map((step) => ({ argv: step.argv, kind: "argv" as const }))
}

/// Unambiguous display form for logs and consent. JSON string quoting keeps
/// whitespace and empty arguments visible without implying shell execution.
export const displayPluginCommand = (command: ResolvedPluginCommand): string =>
  command.kind === "shell" ? command.command : command.argv.map(displayArgument).join(" ")

const displayArgument = (argument: string): string =>
  /^[A-Za-z0-9_./:@%+=,-]+$/.test(argument) ? argument : JSON.stringify(argument)
