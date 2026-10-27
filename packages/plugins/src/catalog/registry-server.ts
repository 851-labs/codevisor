export interface RegistryInput {
  readonly name?: string
  readonly description?: string
  readonly isRequired?: boolean
  readonly isSecret?: boolean
  readonly default?: string
  readonly format?: string
  readonly type?: string
  readonly value?: string
  readonly valueHint?: string
  readonly choices?: ReadonlyArray<string>
}

export interface RegistryPackage {
  readonly registryType: string
  readonly identifier: string
  readonly version?: string
  readonly runtimeHint?: string
  readonly transport?: { readonly type?: string }
  readonly environmentVariables?: ReadonlyArray<RegistryInput>
  readonly packageArguments?: ReadonlyArray<RegistryInput>
  readonly runtimeArguments?: ReadonlyArray<RegistryInput>
}

export interface RegistryRemote {
  readonly type: string
  readonly url: string
  readonly headers?: ReadonlyArray<RegistryInput>
}

export interface RegistryServer {
  readonly name: string
  readonly title?: string
  readonly description?: string
  readonly version?: string
  readonly websiteUrl?: string
  readonly icons?: ReadonlyArray<{ readonly src: string }>
  readonly packages?: ReadonlyArray<RegistryPackage>
  readonly remotes?: ReadonlyArray<RegistryRemote>
  readonly _meta?: Readonly<Record<string, unknown>>
}

export const codevisorPluginMeta = "dev.codevisor/plugin"

export const parseRegistryServer = (value: unknown): RegistryServer | undefined =>
  isRegistryServer(value) ? value : undefined

const isRegistryServer = (value: unknown): value is RegistryServer =>
  isRecord(value) && typeof value.name === "string" && value.name !== ""

export const registryServersOf = (body: unknown): ReadonlyArray<RegistryServer> => {
  if (!isRecord(body) || !Array.isArray(body.servers)) return []
  return body.servers.flatMap((item) => {
    const server = parseRegistryServer(isRecord(item) && "server" in item ? item.server : item)
    return server === undefined ? [] : [server]
  })
}

export const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)
