export const maxPluginIdLength = 200

export const isPluginId = (value: unknown): value is string =>
  typeof value === "string" &&
  value.length <= maxPluginIdLength &&
  (registryNamePattern.test(value) || customIdPattern.test(value))

export const isPublisher = (value: string): boolean => publisherPattern.test(value)

export const pluginPublisher = (id: string): string => {
  if (id.startsWith(customPrefix)) return id.slice(customPrefix.length).toLowerCase()
  return id.slice(0, id.indexOf("/")).toLowerCase()
}

export const pluginPageUrl = (id: string): string =>
  `https://www.codevisor.dev/plugins/${encodeURIComponent(id)}`

const customPrefix = "custom:"
const registryNamePattern = /^[a-zA-Z0-9.-]+\/[a-zA-Z0-9._-]+$/
const customIdPattern = /^custom:[^\s\p{Cc}]+$/u
const publisherPattern = /^[a-z0-9][a-z0-9.-]{0,199}$/
