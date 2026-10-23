export interface KeyedDrains {
  readonly drain: (key: string) => Promise<void>
}

export const makeKeyedDrains = (drainOnce: (key: string) => Promise<void>): KeyedDrains => {
  const running = new Map<string, Promise<void>>()
  const requested = new Set<string>()

  const loop = async (key: string): Promise<void> => {
    while (requested.delete(key)) await drainOnce(key).catch(() => undefined)
    running.delete(key)
  }

  return {
    drain: (key) => {
      requested.add(key)
      const current = running.get(key)
      if (current !== undefined) return current
      const started = loop(key)
      running.set(key, started)
      return started
    }
  }
}
