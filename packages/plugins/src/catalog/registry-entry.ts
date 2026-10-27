import type {
  ConfigField,
  PluginAccountSpec,
  PluginAgeRating,
  PluginCapabilities,
  PluginCatalogEntry,
  PluginCatalogSource,
  PluginInstallSpec
} from "@codevisor/api"

import {
  codevisorPluginMeta,
  isRecord,
  type RegistryInput,
  type RegistryPackage,
  type RegistryRemote,
  type RegistryServer
} from "./registry-server.js"

export interface CodevisorPluginMeta {
  readonly bundled?: string
  readonly ageRating?: number
  readonly entry?: string
  readonly devOnly?: boolean
  readonly accounts?: PluginAccountSpec
  readonly capabilities?: PluginCapabilities
}

export const emptyCapabilities: PluginCapabilities = {
  tools: [],
  events: [],
  skills: [],
  panes: [],
  ingress: []
}

export const publisherProvidedMeta = "io.modelcontextprotocol.registry/publisher-provided"

export const pluginMetaOf = (server: RegistryServer): CodevisorPluginMeta | undefined => {
  const direct = server._meta?.[codevisorPluginMeta]
  if (isRecord(direct)) return direct
  const provided = server._meta?.[publisherProvidedMeta]
  const nested = isRecord(provided) ? provided[codevisorPluginMeta] : undefined
  return isRecord(nested) ? thirdPartyMeta(nested) : undefined
}

const thirdPartyMeta = (meta: CodevisorPluginMeta): CodevisorPluginMeta => {
  const { bundled: _bundled, entry: _entry, devOnly: _devOnly, ...rest } = meta
  return rest
}

export const catalogEntryOf = (
  server: RegistryServer,
  source: PluginCatalogSource
): PluginCatalogEntry | undefined => {
  const meta = pluginMetaOf(server)
  const install = installOf(server, meta)
  if (install === undefined) return undefined
  return {
    id: server.name,
    name: server.title ?? lastSegment(server.name),
    description: server.description ?? "",
    publisher: publisherOf(server.name),
    version: server.version ?? "latest",
    source,
    transport: install.kind === "remote" ? "http" : "stdio",
    ...(install.kind === "remote" ? { url: install.url } : {}),
    ...(server.icons?.[0] === undefined ? {} : { iconUrl: server.icons[0].src }),
    ...(server.websiteUrl === undefined ? {} : { docsUrl: server.websiteUrl }),
    install,
    ...ageRatingOf(meta),
    ...(meta?.accounts === undefined ? {} : { accounts: meta.accounts }),
    capabilities: meta?.capabilities ?? emptyCapabilities
  }
}

const ageRatings: ReadonlyArray<PluginAgeRating> = [4, 9, 13, 16, 18]

const ageRatingOf = (
  meta: CodevisorPluginMeta | undefined
): { readonly ageRating?: PluginAgeRating } => {
  const rating = ageRatings.find((candidate) => candidate === meta?.ageRating)
  return rating === undefined ? {} : { ageRating: rating }
}

export const argumentPlaceholder = (index: number): string => `\${arg:${index}}`

const installOf = (
  server: RegistryServer,
  meta: CodevisorPluginMeta | undefined
): PluginInstallSpec | undefined => {
  if (meta?.bundled !== undefined) return { kind: "bundled" }
  const remote = server.remotes?.find((candidate) => candidate.type === "streamable-http")
  if (remote !== undefined) return remoteInstall(remote)
  const runnable = server.packages?.map(packageInstall).find((install) => install !== undefined)
  return runnable
}

const remoteInstall = (remote: RegistryRemote): PluginInstallSpec => ({
  kind: "remote",
  url: remote.url,
  fields: (remote.headers ?? []).flatMap((header) => inputField("header", header))
})

const packageInstall = (pkg: RegistryPackage): PluginInstallSpec | undefined => {
  if (pkg.transport?.type !== undefined && pkg.transport.type !== "stdio") return undefined
  const runner = runners[pkg.registryType]
  if (runner === undefined) return undefined
  const launched = runner(pkg)
  return {
    kind: "package",
    registryType: pkg.registryType,
    command: launched.command,
    args: [...launched.args, ...argumentTemplate(pkg.packageArguments ?? [])],
    fields: [
      ...(pkg.environmentVariables ?? []).flatMap((variable) => inputField("env", variable)),
      ...argumentFields(pkg.packageArguments ?? [])
    ]
  }
}

interface Launched {
  readonly command: string
  readonly args: ReadonlyArray<string>
}

const runners: Readonly<Record<string, (pkg: RegistryPackage) => Launched>> = {
  npm: (pkg) => ({ command: pkg.runtimeHint ?? "npx", args: ["-y", versioned(pkg, "@")] }),
  pypi: (pkg) => ({ command: pkg.runtimeHint ?? "uvx", args: [versioned(pkg, "==")] }),
  oci: (pkg) => ({
    command: "docker",
    args: [
      "run",
      "-i",
      "--rm",
      ...(pkg.environmentVariables ?? []).flatMap((variable) =>
        variable.name === undefined ? [] : ["-e", variable.name]
      ),
      versioned(pkg, ":")
    ]
  })
}

const versioned = (pkg: RegistryPackage, separator: string): string =>
  pkg.version === undefined || pkg.version === "latest"
    ? pkg.identifier
    : `${pkg.identifier}${separator}${pkg.version}`

const argumentTemplate = (inputs: ReadonlyArray<RegistryInput>): ReadonlyArray<string> =>
  inputs.flatMap((input, index) => argumentParts(input, index))

const argumentParts = (input: RegistryInput, index: number): ReadonlyArray<string> => {
  const value = input.value ?? (input.isRequired === true ? argumentPlaceholder(index) : undefined)
  if (value === undefined) return []
  if (input.type !== "named" || input.name === undefined) return [value]
  return [flagOf(input.name), value]
}

const argumentFields = (inputs: ReadonlyArray<RegistryInput>): ReadonlyArray<ConfigField> =>
  inputs.flatMap((input, index) => {
    if (input.value !== undefined || input.isRequired !== true) return []
    return inputField("arg", { ...input, name: String(index) }, input.name ?? input.valueHint)
  })

const flagOf = (name: string): string => (name.startsWith("-") ? name : `--${name}`)

const inputField = (
  kind: "env" | "header" | "arg",
  input: RegistryInput,
  label?: string
): ReadonlyArray<ConfigField> => {
  if (input.name === undefined) return []
  return [
    {
      key: `${kind}:${input.name}`,
      label: label ?? input.name,
      type: fieldType(input),
      required: input.isRequired === true,
      ...(input.default === undefined ? {} : { default: input.default }),
      ...(input.description === undefined ? {} : { help: input.description }),
      ...(input.choices === undefined
        ? {}
        : { choices: input.choices.map((choice) => ({ value: choice, label: choice })) })
    }
  ]
}

const fieldType = (input: RegistryInput): ConfigField["type"] => {
  if (input.isSecret === true) return "secret"
  if (input.choices !== undefined) return "choice"
  if (input.format === "boolean") return "boolean"
  if (input.format === "number") return "number"
  return "string"
}

const lastSegment = (name: string): string => name.slice(name.lastIndexOf("/") + 1)

const publisherOf = (name: string): string => name.slice(0, Math.max(0, name.indexOf("/"))) || name
