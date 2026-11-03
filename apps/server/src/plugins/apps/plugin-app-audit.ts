export interface AppLogSource {
  readonly serverId: string
  readonly resourceUri: string
  readonly viewId?: string
}

export interface AppAudit {
  readonly policy: (source: AppLogSource, policy: string) => void
  readonly message: (source: AppLogSource, params: Readonly<Record<string, unknown>>) => void
}

export const makeAppAudit = (write: (line: string) => void = defaultWrite): AppAudit => {
  const audited = new Set<string>()
  return {
    policy: (source, policy) => {
      const key = `${source.serverId}|${source.resourceUri}|${policy}`
      if (audited.has(key)) return
      audited.add(key)
      write(JSON.stringify({ event: "plugin_app_csp", ...source, policy }))
    },
    message: (source, params) => {
      write(
        JSON.stringify({
          event: "plugin_app_log",
          ...source,
          level: typeof params.level === "string" ? params.level : "info",
          ...(typeof params.logger === "string" ? { logger: params.logger } : {}),
          data: cappedData(params.data)
        })
      )
    }
  }
}

const maxLoggedCharacters = 4_000

const cappedData = (data: unknown): string => {
  const text = typeof data === "string" ? data : (JSON.stringify(data) ?? "")
  if (text.length <= maxLoggedCharacters) return text
  return `${text.slice(0, maxLoggedCharacters)}…`
}

const defaultWrite = (line: string): void => {
  console.error(line)
}
